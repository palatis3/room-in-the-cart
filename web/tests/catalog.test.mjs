import assert from 'node:assert/strict';
import test from 'node:test';
import {readFileSync} from 'node:fs';
import ts from 'typescript';
import {spanishKeys,translate} from '../dist/i18n.js';

test('all static interface labels and outcomes have US Spanish copy',()=>{
 const file=ts.createSourceFile('app.ts',readFileSync(new URL('../src/app.ts',import.meta.url),'utf8'),ts.ScriptTarget.Latest,true);
 const keys=new Set();
 const literals=node=>{if(!node)return;if(ts.isStringLiteral(node)&&node.text)keys.add(node.text);else if(ts.isConditionalExpression(node)){literals(node.whenTrue);literals(node.whenFalse);}else if(ts.isBinaryExpression(node)&&node.operatorToken.kind===ts.SyntaxKind.QuestionQuestionToken)literals(node.right);};
 const walk=node=>{
  if(ts.isCallExpression(node)&&ts.isPropertyAccessExpression(node.expression)){
   const name=node.expression.name.text;
   if(name==='t'||name==='button')literals(node.arguments[0]);
   if(name==='field')literals(node.arguments[1]);
  }
  if(ts.isBinaryExpression(node)&&ts.isPropertyAccessExpression(node.left)&&node.left.name.text==='notice')literals(node.right);
  if(ts.isVariableDeclaration(node)&&ts.isIdentifier(node.name)&&node.name.text==='statuses'&&node.initializer&&ts.isObjectLiteralExpression(node.initializer)){
   for(const property of node.initializer.properties)if(ts.isPropertyAssignment(property))literals(property.initializer);
  }
  ts.forEachChild(node,walk);
 };
 walk(file);assert.ok(keys.size>65);
 const available=new Set(spanishKeys);
 for(const key of keys){assert.ok(available.has(key),`Missing Spanish: ${key}`);assert.notEqual(translate(key,'es'),key,`Untranslated: ${key}`);}
});
