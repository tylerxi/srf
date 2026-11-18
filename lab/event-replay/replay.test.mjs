import test from 'node:test';
import assert from 'node:assert/strict';
import {replay, fixtures} from './replay.mjs';

test('rejects unbounded delays, excessive events and arbitrary event types before dispatch', async () => {
  for (const step of [
    {type: 'keydown', delayMs: -1},
    {type: 'keydown', delayMs: Infinity},
    {type: 'keydown', delayMs: 5001},
    {type: 'paste'},
    {type: 'click'},
    {type: 'keydown', edit: 'selection'},
    {type: 'beforeinput', edit: 'unknown'},
    {type: 'beforeinput', data: 'a'.repeat(8193)},
  ]) {
    await assert.rejects(replay(null, {name: 'invalid', steps: [step]}), TypeError);
  }
  await assert.rejects(replay(null, {name: 'overflow', steps: Array(2001).fill({type: 'keyup'})}), TypeError);
});

test('rejects missing and non-DOM input targets', async () => {
  for (const target of [null, undefined, {}, {tagName: 'DIV'}]) {
    await assert.rejects(replay(target, fixtures.keyboard), /editable text input/);
  }
});

test('module imports without browser globals or side effects', () => {
  assert.deepEqual(Object.keys(fixtures), ['keyboard', 'composition', 'multiCharacter']);
  assert.equal(globalThis.document, undefined);
});
