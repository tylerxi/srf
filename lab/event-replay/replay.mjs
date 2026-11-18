/** Explicit synthetic fixtures for testing an input detector on an owned page.
 * These events are not native IME events: Event.isTrusted remains false.
 * No network access, clipboard access, global hooks, or detector modification.
 */
const MAX_STEPS = 2000;
const MAX_DELAY_MS = 5000;
const MARKER = 'input-lab:replay';

export const fixtures = Object.freeze({
  keyboard: Object.freeze({
    name: 'ASCII 按键配对与时序',
    steps: [
      {type: 'keydown', key: 'a', code: 'KeyA'},
      {type: 'beforeinput', inputType: 'insertText', data: 'a', edit: 'selection'},
      {type: 'keyup', key: 'a', code: 'KeyA', delayMs: 90},
      {type: 'keydown', key: 'b', code: 'KeyB', delayMs: 130},
      {type: 'beforeinput', inputType: 'insertText', data: 'b', edit: 'selection'},
      {type: 'keyup', key: 'b', code: 'KeyB', delayMs: 80},
    ],
  }),
  composition: Object.freeze({
    name: '合成组合输入序列（非原生输入法）',
    steps: [
      {type: 'compositionstart', data: ''},
      {type: 'keydown', key: 'Process', code: '', isComposing: true},
      {type: 'compositionupdate', data: 'n'},
      {type: 'beforeinput', inputType: 'insertCompositionText', data: 'n', isComposing: true, edit: 'composition'},
      {type: 'keyup', key: 'Process', code: '', isComposing: true, delayMs: 80},
      {type: 'keydown', key: 'Process', code: '', isComposing: true, delayMs: 120},
      {type: 'compositionupdate', data: 'ni'},
      {type: 'beforeinput', inputType: 'insertCompositionText', data: 'ni', isComposing: true, edit: 'composition'},
      {type: 'keyup', key: 'Process', code: '', isComposing: true, delayMs: 90},
      {type: 'compositionupdate', data: '你', delayMs: 150},
      {type: 'beforeinput', inputType: 'insertCompositionText', data: '你', isComposing: true, edit: 'composition'},
      {type: 'compositionend', data: '你'},
    ],
  }),
  multiCharacter: Object.freeze({
    name: '单次按键输入两字（异常对照）',
    steps: [
      {type: 'keydown', key: 'Unidentified', code: 'KeyA'},
      {type: 'beforeinput', inputType: 'insertText', data: '中文', edit: 'selection'},
      {type: 'keyup', key: 'Unidentified', code: 'KeyA'},
    ],
  }),
});

function validate(scenario) {
  if (!scenario || typeof scenario.name !== 'string' || scenario.name.length > 200 ||
      !Array.isArray(scenario.steps) || scenario.steps.length > MAX_STEPS) {
    throw new TypeError('Invalid replay scenario');
  }
  const types = new Set(['keydown', 'keyup', 'beforeinput',
    'compositionstart', 'compositionupdate', 'compositionend']);
  for (const step of scenario.steps) {
    if (!step || !types.has(step.type) ||
        !Number.isFinite(step.delayMs ?? 0) || (step.delayMs ?? 0) < 0 ||
        (step.delayMs ?? 0) > MAX_DELAY_MS ||
        (step.edit != null && !['selection', 'composition'].includes(step.edit)) ||
        (step.edit != null && step.type !== 'beforeinput')) {
      throw new TypeError('Invalid replay step');
    }
    for (const field of ['key', 'code', 'data', 'inputType']) {
      if (step[field] != null && (typeof step[field] !== 'string' || step[field].length > 8192)) {
        throw new TypeError(`Invalid ${field}`);
      }
    }
  }
}

function pause(ms, signal, view) {
  if (signal?.aborted) return Promise.reject(signal.reason ?? new DOMException('Aborted', 'AbortError'));
  return new Promise((resolve, reject) => {
    const abort = () => {
      view.clearTimeout(timer);
      reject(signal.reason ?? new DOMException('Aborted', 'AbortError'));
    };
    const timer = view.setTimeout(() => {
      signal?.removeEventListener('abort', abort);
      resolve();
    }, ms);
    signal?.addEventListener('abort', abort, {once: true});
  });
}

const activeTargets = new WeakSet();

/** Replay explicitly chosen test events into a text input or textarea.
 * KeyboardEvent dispatch does not type text, so edits are applied explicitly
 * between beforeinput and input. This models a fixture, not native behavior.
 * beforeinput cancellation is honored and recorded; it is never bypassed.
 */
export async function replay(target, scenario = fixtures.keyboard, {signal} = {}) {
  validate(scenario);
  const view = target?.ownerDocument?.defaultView;
  if (!view || !['TEXTAREA', 'INPUT'].includes(target.tagName) ||
      (target.tagName === 'INPUT' && !['text', 'search', 'url', 'tel'].includes(target.type)) ||
      target.disabled || target.readOnly || !target.isConnected || activeTargets.has(target)) {
    throw new TypeError('Choose a connected, editable text input or textarea without an active replay');
  }
  if (signal?.aborted) throw signal.reason ?? new DOMException('Aborted', 'AbortError');
  const report = {
    schemaVersion: 1, fixture: scenario.name, source: 'synthetic-fixture',
    isNativeIME: false, startedAt: new Date().toISOString(), events: [],
    outcome: 'running', elapsedMs: 0,
  };
  const started = view.performance.now();
  let composition = null;
  let keyAccepted = true;
  const dispatch = (type, fields = {}) => {
    const base = {bubbles: true, composed: true, cancelable: type !== 'input', ...fields};
    const event = type.startsWith('key') ? new view.KeyboardEvent(type, base)
      : type.startsWith('composition') ? new view.CompositionEvent(type, {...base, cancelable: false})
      : new view.InputEvent(type, base);
    const accepted = target.dispatchEvent(event);
    report.events.push({type, atMs: view.performance.now() - started,
      isTrusted: event.isTrusted, key: event.key, code: event.code,
      inputType: event.inputType, data: event.data,
      isComposing: event.isComposing, defaultPrevented: event.defaultPrevented});
    return accepted;
  };
  const marker = phase => target.dispatchEvent(new view.CustomEvent(MARKER, {
    bubbles: true, detail: {phase, source: report.source, fixture: scenario.name},
  }));
  activeTargets.add(target);
  marker('start');
  try {
    for (const step of scenario.steps) {
      await pause(step.delayMs ?? 0, signal, view);
      if (!target.isConnected || target.disabled || target.readOnly) {
        throw new Error('Target is no longer editable');
      }
      if (step.type === 'compositionstart') {
        composition = {start: target.selectionStart, end: target.selectionEnd};
      }
      const accepted = dispatch(step.type, step);
      if (step.type === 'keydown') keyAccepted = accepted;
      if (step.type === 'beforeinput' && step.edit && accepted && keyAccepted) {
        const start = step.edit === 'composition' && composition ? composition.start : target.selectionStart;
        const end = step.edit === 'composition' && composition ? composition.end : target.selectionEnd;
        const data = step.data ?? '';
        target.setRangeText(data, start, end, 'end');
        if (step.edit === 'composition' && composition) composition.end = start + data.length;
        dispatch('input', step);
      }
      if (step.type === 'keyup') keyAccepted = true;
      if (step.type === 'compositionend') composition = null;
    }
    report.outcome = 'completed';
  } catch (error) {
    report.outcome = signal?.aborted ? 'aborted' : 'failed';
    report.error = String(error?.message ?? error);
  } finally {
    activeTargets.delete(target);
    report.elapsedMs = view.performance.now() - started;
    marker(report.outcome);
  }
  return report;
}

export function downloadReport(report, document = globalThis.document) {
  const view = document.defaultView;
  const url = view.URL.createObjectURL(new view.Blob([JSON.stringify(report, null, 2)], {type: 'application/json'}));
  const link = document.createElement('a');
  link.href = url; link.download = 'input-fixture-report.json'; link.click();
  view.setTimeout(() => view.URL.revokeObjectURL(url), 1000);
}
