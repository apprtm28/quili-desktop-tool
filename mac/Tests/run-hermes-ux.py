#!/usr/bin/env python3
"""Run the real Hermes controller headlessly with deterministic external-service doubles.
No SSH, Keychain, user settings, Slack, or live app state is accessed.
"""
from pathlib import Path
import subprocess
import tempfile

mac = Path(__file__).resolve().parents[1]
sources = mac / 'Sources/Quili'
def read(path):
    return (sources / path).read_text()

# Keep production declarations verbatim; append tests in the same compilation unit
# to exercise private state transitions without adding test-only APIs to the app.
model = read('Services/HermesSessions.swift')
values = model[model.index('struct HermesSource:'):model.index('/// The sources discussed')]
identity = model[model.index('    static func key(kind:'):model.index('    // MARK: - Storage')]
store = '''@MainActor final class HermesSessions {
    static let shared = HermesSessions()
    private var records: [String: HermesSource] = [:]
    func source(_ key: String) -> HermesSource? { records[key] }
    func save(_ source: HermesSource) { records[source.key] = source }
    func forget(_ key: String) { records[key] = nil }
''' + identity + '\n}\n'
reader = read('Accessibility/ThreadReader.swift')
reader_values = reader[:reader.index('/// Reads the thread pane')]
window_values = read('UI/ConversationWindow.swift').split('// MARK: - Pieces')[0]
client_values = read('Services/HermesClient.swift').split('/// Talks to the Hermes agent')[0]
combined = '\n'.join([values, store, reader_values, window_values, client_values,
                       read('Services/Prompts.swift'), read('App/HermesController.swift'),
                       (mac / 'Tests/HermesUXHarness.swift').read_text()])
with tempfile.TemporaryDirectory(prefix='quili-ux-') as temp:
    temp = Path(temp)
    unit = temp / 'Tests.swift'
    unit.write_text(combined)
    flags = ['-swift-version', '5', '-parse-as-library', '-module-cache-path', str(temp / 'cache')]
    duplicate = Path('/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap')
    if duplicate.exists() and duplicate.with_name('bridging.modulemap').exists():
        import json
        empty = temp / 'empty.modulemap'
        empty.touch()
        overlay = temp / 'overlay.json'
        overlay.write_text(json.dumps({'version': 0, 'roots': [{'type': 'file', 'name': str(duplicate), 'external-contents': str(empty)}]}))
        flags += ['-vfsoverlay', str(overlay), '-Xcc', '-ivfsoverlay', '-Xcc', str(overlay)]
    subprocess.run(['swiftc', *flags, str(unit), '-o', str(temp / 'tests')], check=True)
    subprocess.run([str(temp / 'tests')], check=True, timeout=30)
