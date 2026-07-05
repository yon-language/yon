// Yon Language Support: launches the yon-lsp language server and surfaces its
// three faces through one client, diagnostics (compiler errors + linter
// warnings), formatting, and the navigation providers (hover, symbols,
// completion). The linter and formatter are not separate processes: yon-lsp
// already emits Wxxxx warnings and answers textDocument/formatting, so the
// settings below just gate what reaches the editor.
const { workspace } = require('vscode');
const { LanguageClient, TransportKind } = require('vscode-languageclient/node');

let client;

// A diagnostic is a linter warning iff its code starts with 'W' (errors are E).
function isLintDiagnostic(d) {
  const c = d && d.code;
  const v = c && typeof c === 'object' ? c.value : c;
  return typeof v === 'string' && v.charAt(0) === 'W';
}

function activate(_context) {
  const bin = workspace.getConfiguration('yon').get('lspPath') || 'yon-lsp';
  const serverOptions = {
    run: { command: bin, transport: TransportKind.stdio },
    debug: { command: bin, transport: TransportKind.stdio }
  };
  const clientOptions = {
    documentSelector: [{ scheme: 'file', language: 'yon' }],
    middleware: {
      // yon.lint.enable: drop the Wxxxx warnings, keep the errors.
      handleDiagnostics: (uri, diagnostics, next) => {
        if (!workspace.getConfiguration('yon').get('lint.enable', true)) {
          diagnostics = diagnostics.filter((d) => !isLintDiagnostic(d));
        }
        next(uri, diagnostics);
      },
      // yon.format.enable: decline formatting when the user turns it off.
      provideDocumentFormattingEdits: (document, options, token, next) => {
        if (!workspace.getConfiguration('yon').get('format.enable', true)) return [];
        return next(document, options, token);
      }
    }
  };
  // Client id 'yon' -> the trace setting is read from 'yon.trace.server'.
  client = new LanguageClient('yon', 'Yon Language Server', serverOptions, clientOptions);
  client.start();
}

function deactivate() {
  return client ? client.stop() : undefined;
}

module.exports = { activate, deactivate };
