fs = require 'fs'
fix = 
"""
interface ArrayBufferView {}
declare var ArrayBufferView: {};

interface ArrayBuffer {}
declare var ArrayBuffer: {};

interface Uint8Array {}
declare var Uint8Array: {};

interface Int32Array {}
declare var Int32Array: {};

interface Float32Array {}
declare var Float32Array: {};
"""


SupAPI.registerPlugin('typescript-server', 'node', {
  defs: fs.readFileSync(__dirname + '/../typings/node/node.d.ts', encoding: 'utf8') + fix
});

SupAPI.registerPlugin 'typescript-server', 'lib', {
  defs: fs.readFileSync "#{__dirname}/../../../sparklinlabs/typescript/api/lib.d.ts.txt", encoding: 'utf8'
}
