// Client VSCode minimo: lancia il binario yon_lsp come language server.
// Builda l'estensione: npm install && vsce package  (oppure F5 in dev).
const { workspace } = require('vscode');
const { LanguageClient, TransportKind } = require('vscode-languageclient/node');

let client;
function activate(context) {
  // Path al binario: configurabile via settings yon.lspPath, default al build dune.
  const bin = workspace.getConfiguration('yon').get('lspPath')
    || 'frontend/_build/default/yon_lsp.exe';
  const serverOptions = {
    run:   { command: bin, transport: TransportKind.stdio },
    debug: { command: bin, transport: TransportKind.stdio }
  };
  const clientOptions = {
    documentSelector: [{ scheme: 'file', language: 'yon' }]
  };
  client = new LanguageClient('yon-lsp', 'Yon LSP', serverOptions, clientOptions);
  client.start();
}
function deactivate() { return client ? client.stop() : undefined; }
module.exports = { activate, deactivate };
