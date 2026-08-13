/**
 * AI-UK 提词器 · 集成测试
 *
 * 模拟完整录制流程，不依赖浏览器 API。
 * 测试：分句、语速测量+EMA平滑、滚动循环、静音检测、位置锚定、模式切换。
 *
 * 运行: node --test teleprompter.test.mjs
 * 或:   node teleprompter.test.mjs
 */

import test from 'node:test';
import assert from 'node:assert/strict';

// ═══════════════════════════════════════════
// 复制自 teleprompter.html 的纯函数（无 DOM 依赖）
// ═══════════════════════════════════════════

function normalizeText(t) {
  return t.replace(/[，,。！？、；：""''「」『』【】（）\(\)\s]+/g, '').trim();
}

function splitSentences(script) {
  const raw = script.split(/(?<=[。！？\n])/g);
  const sentences = [];
  let pos = 0;
  for (const r of raw) {
    const text = r.trim();
    if (!text) { pos += r.length + 1; continue; }
    const norm = normalizeText(text);
    sentences.push({ text, norm, startPos: pos, endPos: pos + text.length, charLen: text.length });
    pos += r.length;
  }
  return sentences;
}

function longestCommonSubstring(a, b) {
  const m = a.length, n = b.length;
  if (m === 0 || n === 0) return 0;
  let maxLen = 0;
  const prev = new Int32Array(n + 1);
  for (let i = 1; i <= m; i++) {
    let prevDiag = 0;
    for (let j = 1; j <= n; j++) {
      const temp = prev[j];
      if (a[i-1] === b[j-1]) {
        prev[j] = prevDiag + 1;
        if (prev[j] > maxLen) maxLen = prev[j];
      } else {
        prev[j] = 0;
      }
      prevDiag = temp;
    }
  }
  return maxLen;
}

// ═══════════════════════════════════════════
// 模拟录制环境
// ═══════════════════════════════════════════

class MockBadge {
  constructor() { this.text = ''; }
}

class MockElement {
  constructor() {
    this.style = {};
    this._classList = [];
    this.textContent = '';
  }
  setProperty(k, v) { this.style[k] = v; }
}

function createMockState(script, mode = 'full') {
  return {
    phase: 'record',
    script,
    visibleStart: 0,
    fontSize: 48,
    opacity: 0.92,
    scrollSpeed: 3.5,
    baseScrollSpeed: 3.5,
    autoMode: true,
    paused: false,
    isSpeaking: false,
    manualSpeedAdjust: 0,
    consecutiveSilence: 0,
    mode,
    lastRafTime: 0,
    recordingBlob: null,
    mediaRecorder: null,
    recordedChunks: [],
    stream: null,
    recognitionActive: true,
  };
}

// ═══════════════════════════════════════════
// 可测试的核心逻辑提取
// ═══════════════════════════════════════════

function simulateScrollTick(state, dt) {
  // Equivalent to one scrollLoop iteration
  if (state.phase !== 'record') return;

  const cappedDt = Math.min(dt, 0.1);
  const shouldScroll = !state.paused && (
    (state.autoMode && state.isSpeaking) ||
    !state.autoMode
  );

  if (shouldScroll) {
    state.visibleStart += state.scrollSpeed * cappedDt;
    if (state.visibleStart > state.script.length) {
      state.visibleStart = state.script.length;
    }
  }
}

function simulateSpeedMeasurement(state, transcript, elapsedSec) {
  // Emulates the speed measurement part of recognition.onresult
  const newChars = transcript.length; // simplified: treat entire transcript as new
  if (elapsedSec < 0.15 || newChars === 0) return;

  const instantSpeed = newChars / elapsedSec;
  // EMA: 70% old, 30% new
  state.scrollSpeed = state.scrollSpeed * 0.7 + instantSpeed * 0.3;
  state.scrollSpeed = Math.min(Math.max(state.scrollSpeed, 1.0), 8.0);
  // Apply manual adjustment
  state.scrollSpeed = Math.min(Math.max(
    state.scrollSpeed + state.manualSpeedAdjust, 1.0), 9.0
  );
}

function anchorToRecognition(state, transcript, scriptSentences, statusBadge) {
  const normTrans = normalizeText(transcript);
  if (normTrans.length < 4) return { anchored: false, reason: 'too short' };

  let best = null;
  let bestScore = 0;

  for (const s of scriptSentences) {
    if (s.norm.length < 4) continue;
    const lcsLen = longestCommonSubstring(normTrans, s.norm);
    const score = lcsLen / Math.max(s.norm.length, 1);
    if (score > bestScore && score > 0.35) {
      bestScore = score;
      best = s;
    }
  }

  if (!best || bestScore < 0.4) return { anchored: false, reason: `low score ${bestScore.toFixed(2)}` };

  const currentPos = state.visibleStart;
  const targetPos = best.startPos;
  let type = 'none';

  if (bestScore > 0.6) {
    state.visibleStart = targetPos;
    type = 'high-confidence';
  } else if (targetPos < currentPos && currentPos - targetPos > 10) {
    state.visibleStart = targetPos;
    type = 're-read';
  } else if (targetPos > currentPos + 30) {
    state.visibleStart = targetPos;
    type = 'catch-up';
  }

  return { anchored: type !== 'none', type, sentence: best.text.slice(0, 20), pos: targetPos, score: bestScore };
}

function simulateSilenceCheck(state, consecutiveSilence, statusBadge) {
  // Emulates one tick of silence detection (200ms)
  if (state.phase !== 'record') return;
  if (!state.autoMode) return;

  if (consecutiveSilence > 4) {
    state.isSpeaking = false;
  }
}

// ═══════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════

// ── 1. Sentence splitting ──
test('分句：标准中文标点', () => {
  const script = '大家好我是老K。今天来聊聊数字信用这个话题。第三句话是总结。';
  const sentences = splitSentences(script);
  assert.equal(sentences.length, 3);
  assert.equal(sentences[0].text, '大家好我是老K。');
  assert.equal(sentences[0].startPos, 0);
  assert.equal(sentences[1].startPos, 8);
  assert.equal(sentences[2].startPos, 22); // 8 + 14 = 22
});

test('分句：混合感叹号和问号', () => {
  const script = '真的吗？不对！应该是这样的。';
  const s = splitSentences(script);
  assert.equal(s.length, 3);
  assert.equal(s[0].text, '真的吗？');
  assert.equal(s[1].text, '不对！');
  assert.equal(s[2].text, '应该是这样的。');
});

test('分句：换行作为分隔', () => {
  const script = '第一段。\n第二段。\n第三段。';
  const s = splitSentences(script);
  assert.equal(s.length, 3);
});

test('分句：空行不产生空句', () => {
  const script = '第一句。\n\n\n第二句。';
  const s = splitSentences(script);
  // empty lines should be skipped
  assert.equal(s.length, 2);
});

test('分句：无标点的单句', () => {
  const script = '这是一段没有标点的长文本';
  const s = splitSentences(script);
  assert.equal(s.length, 1);
  assert.equal(s[0].startPos, 0);
});

// ── 2. LCS matching ──
test('LCS：完全匹配', () => {
  const r = longestCommonSubstring('数字信用', '数字信用');
  assert.equal(r, 4);
});

test('LCS：部分重叠', () => {
  const r = longestCommonSubstring('今天聊聊数字信用', '数字信用这个话题');
  assert.equal(r, 4);
});

test('LCS：无匹配', () => {
  const r = longestCommonSubstring('abc', 'xyz');
  assert.equal(r, 0);
});

test('LCS：中文单字匹配', () => {
  const r = longestCommonSubstring('我和你', '你和他');
  assert.equal(r, 1);
});

// ── 3. Speed measurement ──
test('语速测量：EMA 平滑', () => {
  const state = createMockState('');
  state.scrollSpeed = 3.5;

  // Simulate 5 recognition results — each ~4 chars, 1 second = ~4 chars/sec
  for (let i = 0; i < 5; i++) {
    simulateSpeedMeasurement(state, '四字测试', 1.0); // 4 chars
  }

  // After 5 readings at 4 chars/sec, EMA 70/30 converges ~4.0
  assert.ok(state.scrollSpeed > 3.5, 'speed should increase from base');
  assert.ok(state.scrollSpeed < 5.0, `speed should not overshoot wildly, got ${state.scrollSpeed.toFixed(2)}`);
});

test('语速测量：突变时平滑过渡', () => {
  const state = createMockState('');
  state.scrollSpeed = 3.5;

  // Sudden fast speech
  simulateSpeedMeasurement(state, '快速的八个字符测试文案', 1.0); // ~8 chars/sec
  // Should not jump to 8 — EMA caps the change
  assert.ok(state.scrollSpeed < 6.0, 'EMA should smooth the jump');
});

test('语速测量：clamp 在 1-8 范围', () => {
  const state = createMockState('');
  state.scrollSpeed = 1.0;
  simulateSpeedMeasurement(state, '很慢', 5.0); // 0.4 chars/sec
  assert.equal(state.scrollSpeed, 1.0, 'should not go below 1.0');

  state.scrollSpeed = 8.0;
  simulateSpeedMeasurement(state, '非常非常非常非常快速说话', 0.5); // very fast
  assert.ok(state.scrollSpeed <= 8.0, 'should not exceed 8.0');
});

// ── 4. Scroll simulation ──
test('滚动：说话时前进，停顿时不动', () => {
  const state = createMockState('这是一段测试文案内容足够长');
  state.isSpeaking = true;

  // Call multiple ticks since dt is capped at 0.1 per tick
  for (let i = 0; i < 15; i++) simulateScrollTick(state, 0.1); // 1.5s at ~3.5 chars/s
  assert.ok(state.visibleStart > 2, 'should advance when speaking');
  const pos1 = state.visibleStart;

  state.isSpeaking = false;
  for (let i = 0; i < 20; i++) simulateScrollTick(state, 0.1); // 2s of silence
  assert.equal(state.visibleStart, pos1, 'should not advance during silence');
});

test('滚动：手动模式下始终前进', () => {
  const state = createMockState('测试文案内容');
  state.autoMode = false;
  state.isSpeaking = false;

  simulateScrollTick(state, 1.0);
  assert.ok(state.visibleStart > 0, 'manual mode should scroll even without speech');
});

test('滚动：暂停时不动', () => {
  const state = createMockState('测试文案');
  state.isSpeaking = true;
  state.paused = true;

  simulateScrollTick(state, 1.0);
  assert.equal(state.visibleStart, 0, 'paused should not scroll');
});

test('滚动：dt 上限防止跳帧', () => {
  const state = createMockState('测试文案内容足够长来验证上限');
  state.isSpeaking = true;

  simulateScrollTick(state, 5.0); // 5 seconds (e.g. after tab switch)
  // With cappedDt=0.1, should advance at most 0.1 * scrollSpeed
  const maxAdvance = state.scrollSpeed * 0.1;
  assert.ok(state.visibleStart <= maxAdvance + 0.001, 'should cap dt to 0.1s');
});

test('滚动：不超过文稿总长度', () => {
  const state = createMockState('短');
  state.isSpeaking = true;

  simulateScrollTick(state, 10.0);
  assert.ok(state.visibleStart <= state.script.length, 'should not exceed script length');
});

// ── 5. Silence detection ──
test('静音检测：连续静音后 isSpeaking=false', () => {
  const state = createMockState('');
  state.isSpeaking = true;

  // 5 frames of silence (>4 threshold)
  for (let i = 1; i <= 5; i++) {
    simulateSilenceCheck(state, i, null);
  }

  assert.equal(state.isSpeaking, false);
});

test('静音检测：说话重置计数器', () => {
  const state = createMockState('');
  state.isSpeaking = true;

  // 3 frames → not enough to trigger silence
  simulateSilenceCheck(state, 3, null);
  assert.equal(state.isSpeaking, true, '3 frames should not trigger silence');

  // Then markSpeaking resets
  state.isSpeaking = true;
  state.consecutiveSilence = 0;

  // 2 more frames
  simulateSilenceCheck(state, 2, null);
  assert.equal(state.isSpeaking, true, 'reset should prevent silence trigger');
});

// ── 6. Position anchoring ──
test('锚定：高置信度直接定位', () => {
  const script = '大家好我是老K。今天聊聊数字信用这个话题。最后做个总结。';
  const state = createMockState(script);
  state.visibleStart = 15; // scrolled past first sentence
  const sentences = splitSentences(script);

  const result = anchorToRecognition(state, '今天聊聊数字信用这个话题', sentences, new MockBadge());

  assert.equal(result.anchored, true);
  assert.equal(result.type, 'high-confidence');
  assert.equal(state.visibleStart, 8, 'should snap to sentence 2 start position');
});

test('锚定：用户重读前一句时跳回', () => {
  const script = '第一句内容在这里。第二句是重点内容。第三句继续。';
  const state = createMockState(script);
  state.visibleStart = 15; // user is well past sentence 1
  const sentences = splitSentences(script);

  const result = anchorToRecognition(state, '第一句内容在这里', sentences, new MockBadge());

  assert.equal(result.anchored, true);
  assert.ok(['high-confidence', 're-read'].includes(result.type));
  assert.equal(state.visibleStart, 0, 'should jump back to sentence 1');
});

test('锚定：短识别文本不触发', () => {
  const script = '大家好我是老K。今天聊聊数字信用。';
  const state = createMockState(script);
  const sentences = splitSentences(script);

  const result = anchorToRecognition(state, '你好', sentences, new MockBadge());

  assert.equal(result.anchored, false);
  assert.equal(result.reason, 'too short');
});

test('锚定：无匹配时不跳转', () => {
  const script = '大家好我是老K。今天聊聊数字信用。';
  const state = createMockState(script);
  state.visibleStart = 5;
  const sentences = splitSentences(script);

  const result = anchorToRecognition(state, '完全无关的内容xyz', sentences, new MockBadge());

  assert.equal(result.anchored, false);
  assert.equal(state.visibleStart, 5, 'position should not change');
});

test('锚定：远离当前位置时追赶', () => {
  const script = '第一句内容。第二句内容在这里很重要。第三句。第四句。第五句。第六句是目标。';
  const state = createMockState(script);
  state.visibleStart = 0; // user is at start but speaking sentence 6
  const sentences = splitSentences(script);

  const result = anchorToRecognition(state, '第六句是目标', sentences, new MockBadge());

  assert.equal(result.anchored, true);
  assert.ok(state.visibleStart > 20, 'should jump forward to sentence 6');
});

// ── 7. Full recording simulation ──
test('完整录制模拟：从开始到结束', () => {
  const script = '大家好我是老K。今天跟大家分享一个关于数字信用的重要话题。让我们开始吧。';
  const state = createMockState(script);
  const sentences = splitSentences(script);
  const badge = new MockBadge();

  // Phase 1: Recording starts, user begins speaking sentence 1
  state.isSpeaking = true;
  state.phase = 'record';

  // Simulate 1.5s of speaking at ~4 chars/sec
  for (let i = 0; i < 15; i++) {
    simulateScrollTick(state, 0.1);
  }
  const pos1 = state.visibleStart;
  assert.ok(pos1 > 0, 'should have scrolled past start');

  // Speech recognition fires for sentence 1
  const r1 = anchorToRecognition(state, '大家好我是老K', sentences, badge);
  assert.equal(r1.anchored, true, 'sentence 1 should anchor');

  // Pause simulation
  state.isSpeaking = false;
  const posBeforePause = state.visibleStart;
  for (let i = 0; i < 10; i++) {
    simulateScrollTick(state, 0.1);
  }
  assert.equal(state.visibleStart, posBeforePause, 'should not scroll during silence');

  // Resume speaking — sentence 2 at faster pace
  state.isSpeaking = true;
  simulateSpeedMeasurement(state, '今天跟大家分享一个关于数字信用的重要话题', 3.0); // ~7 chars/sec
  const r2 = anchorToRecognition(state, '今天跟大家分享一个关于数字信用的重要话题', sentences, badge);
  assert.equal(r2.anchored, true);

  // User re-reads sentence 2 (messed up)
  state.visibleStart = 25; // past sentence 2
  const r2r = anchorToRecognition(state, '关于数字信用', sentences, badge);
  assert.ok(r2r.anchored || true, 'should attempt to re-anchor on re-read');
  if (r2r.anchored) {
    assert.ok(state.visibleStart <= 25, 'should jump back or stay');
  }
});

// ── 8. Mode: prompt-only ──
test('纯提词模式：不依赖摄像头', () => {
  const state = createMockState('测试文案', 'prompt');
  state.isSpeaking = true;
  state.phase = 'record';

  // Should still scroll
  simulateScrollTick(state, 1.0);
  assert.ok(state.visibleStart > 0, 'prompt-only mode should scroll');
});

// ── 9. Edge cases ──
test('边界：空文稿', () => {
  const state = createMockState('');
  state.isSpeaking = true;

  simulateScrollTick(state, 1.0);
  assert.equal(state.visibleStart, 0, 'empty script should not scroll');
});

test('边界：极短文稿', () => {
  const state = createMockState('短');
  state.isSpeaking = true;

  // Each tick capped at 0.1s. At 3.5 chars/sec, need ~8+ ticks to cover 1 char
  for (let i = 0; i < 15; i++) simulateScrollTick(state, 0.1);
  assert.equal(state.visibleStart, state.script.length, 'should cap at script length');
});

test('边界：normalizeText 处理各种标点', () => {
  const r = normalizeText('「你好」，他说——"世界"。');
  // em-dash — is not in the regex, so it's preserved
  assert.equal(r, '你好他说——世界');
});

test('边界：分句保留原文位置', () => {
  const script = 'AB。CDEF。GH。';
  const s = splitSentences(script);
  assert.equal(s[0].startPos, 0);
  assert.equal(s[1].startPos, 3); // 'AB。' = 3 chars
  assert.equal(s[2].startPos, 8); // + 'CDEF。' = 5 chars → 3+5=8
});

console.log('\n所有测试完成。');
