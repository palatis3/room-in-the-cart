import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { parseAst } from 'vite';
import { spanishKeys, translate } from '../dist/i18n.js';

test('all static interface labels and outcomes have US Spanish copy', () => {
  const source = readFileSync(new URL('../dist/app.js', import.meta.url), 'utf8');
  const keys = new Set();

  function collectLiteral(node) {
    if (!node) return;
    if (node.type === 'Literal' && typeof node.value === 'string' && node.value) {
      keys.add(node.value);
    } else if (node.type === 'ConditionalExpression') {
      collectLiteral(node.consequent);
      collectLiteral(node.alternate);
    } else if (node.type === 'LogicalExpression' && node.operator === '??') {
      collectLiteral(node.right);
    }
  }

  function visit(node) {
    if (node.type === 'CallExpression' && node.callee.type === 'MemberExpression' && !node.callee.computed) {
      const name = node.callee.property.name;
      if (name === 't' || name === 'button') collectLiteral(node.arguments[0]);
      if (name === 'field') collectLiteral(node.arguments[1]);
    }
    if (node.left?.type === 'MemberExpression' && !node.left.computed && node.left.property.name === 'notice') {
      collectLiteral(node.right);
    }
    if (node.type === 'VariableDeclarator' && node.id.name === 'statuses' && node.init?.type === 'ObjectExpression') {
      for (const property of node.init.properties) collectLiteral(property.value);
    }

    for (const child of Object.values(node)) {
      if (Array.isArray(child)) {
        for (const entry of child) if (entry?.type) visit(entry);
      } else if (child?.type) {
        visit(child);
      }
    }
  }

  visit(parseAst(source));
  assert.ok(keys.size > 65);
  const available = new Set(spanishKeys);
  for (const key of keys) {
    assert.ok(available.has(key), `Missing Spanish: ${key}`);
    assert.notEqual(translate(key, 'es'), key, `Untranslated: ${key}`);
  }
});
