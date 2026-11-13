#!/usr/bin/env python3
"""Schema evolution failures must be caught before supplemental Swift is committed."""
import copy
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location('accessors', SCRIPTS / 'generate-agent-protocol-accessors.py')
accessors = importlib.util.module_from_spec(spec)
spec.loader.exec_module(accessors)
from agent_protocol_model import ROOT, blocks, load_model


class AccessorGenerationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.model, _ = load_model(ROOT / 'shared/Sources/StratoShared/Generated')
        cls.metadata = json.loads((ROOT / 'shared/proto/legacy-json-mapping.json').read_text())

    def test_stale_message_and_field_mappings_are_rejected(self):
        for name, overrides in [('RemovedMessage', {}), ('VMSpec', {'removed_field': {}})]:
            metadata = copy.deepcopy(self.metadata)
            metadata['messages'][name] = overrides
            with self.assertRaisesRegex(ValueError, 'stale|Stale'):
                accessors.generate_legacy(self.model, metadata)

    def test_incompatible_schema_type_requires_a_mapping_decision(self):
        model = copy.deepcopy(self.model)
        model['VMSpec']['fields']['cpus']['native'] = 'String'
        with self.assertRaisesRegex(ValueError, 'Unsupported legacy representation'):
            accessors.generate_legacy(model, self.metadata)

    def test_missing_mapping_cannot_leave_a_handwritten_codec_reference(self):
        metadata = copy.deepcopy(self.metadata)
        del metadata['messages']['VMSpec']
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, 'Codec.swift').write_text(
                'extension Strato_Agent_V1_VMSpec { func encode() { consume(self._jsonCpus) } }')
            with self.assertRaisesRegex(ValueError, 'missing legacy mapping'):
                accessors.validate_references(self.model, metadata, directory)

    def test_mapping_names_are_data_not_executable_swift(self):
        metadata = copy.deepcopy(self.metadata)
        metadata['messages']['VMSpec']['cpus']['name'] = '_jsonCpus { fatalError() }'
        with self.assertRaisesRegex(ValueError, 'invalid/duplicate'):
            accessors.generate_legacy(self.model, metadata)

    def test_documented_example_braces_do_not_change_the_schema_shape(self):
        source = 'message Example {\n // JSON example: {"present": true}\n optional bool present = 1;\n}'
        self.assertIn('optional bool present = 1;', blocks(source, r'message (\w+)\s*\{')['Example'])

    def test_optional_accessors_keep_wrappers_and_native_integer_types(self):
        output = accessors.generate_optional(self.model)
        self.assertIn('public var optionalCpus: Int64?', output)
        self.assertIn('public var optionalNetworks: Strato_Agent_V1_VMSpecNetworksSection?', output)
        self.assertFalse('extension Strato_Agent_V1_VMSpecNetworksSection {' in output)

    def test_legacy_setters_distinguish_field_named_value_from_local_value(self):
        output = accessors.generate_legacy(self.model, self.metadata)
        self.assertIn('self.value = value', output)
        self.assertNotIn('\n                value = value', output)


if __name__ == '__main__':
    unittest.main()
