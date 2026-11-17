"""Read the schema and its pinned SwiftProtobuf output for supplemental generators.

Field types/presence come from .proto; Swift names come from protoc-gen-swift.
Parsing deliberately rejects an unfamiliar shape rather than guessing an API.
"""
from pathlib import Path
import re
import sys
sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
PREFIX = 'Strato_Agent_V1_'


def block_items(source, pattern):
    # Comments may contain example braces; they are not part of the grammar.
    structural = re.sub(r'//[^\n]*', lambda m: ' ' * len(m[0]), source)
    for match in re.finditer(pattern, structural):
        depth, end = 1, match.end()
        while depth:
            if end >= len(source):
                raise ValueError(f'Unclosed declaration: {match[1]}')
            depth += (structural[end] == '{') - (structural[end] == '}')
            end += 1
        yield match[1], source[match.end():end - 1]


def blocks(source, pattern):
    result = {}
    for name, body in block_items(source, pattern):
        if name in result:
            raise ValueError(f'Duplicate declaration: {name}')
        result[name] = body
    return result


def load_model(generated):
    schemas = '\n'.join(path.read_text() for path in sorted((ROOT / 'shared/proto/strato/agent/v1').glob('*.proto')))
    messages = blocks(schemas, r'\bmessage (\w+)\s*\{')
    enums = blocks(schemas, r'\benum (\w+)\s*\{')
    sources = '\n'.join(path.read_text() for path in sorted(Path(generated).glob('*.pb.swift')))
    swift = blocks(sources, r'public (?:nonisolated )?struct (Strato_Agent_V1_\w+)[^{]*\{')
    model = {}
    for name, body in messages.items():
        full_name = PREFIX + name
        swift_body = swift[full_name]
        properties = [(prop.strip('`'), prop, kind.split(' = ', 1)[0].strip()) for prop, kind in re.findall(
            r'public var (`?\w+`?): ([^\n{]+)', swift_body)
            if not prop.startswith('has') and prop != 'unknownFields']
        # The parent of a oneof is already Optional; associated case accessors
        # have no has/clear API. No supplemental optional accessor is needed.
        oneof = re.search(r'\boneof (\w+)\s*\{', body)
        if oneof:
            properties = [p for p in properties if p[0] != oneof[1]]
        fields = re.findall(r'((?:\s*//[^\n]*\n)*)\s*(optional |repeated )?([\w.]+|map<[^>]+>) (\w+) = (\d+);', body)
        if len(fields) != len(properties):
            raise ValueError(f'{name}: schema/Swift field mismatch ({len(fields)} != {len(properties)})')
        parsed = {}
        for (comments, cardinality, kind, field, number), (prop, escaped, native) in zip(fields, properties):
            suffix = 'ID' if prop == 'id' else prop[0].upper() + prop[1:]
            has = 'has' + suffix
            clear = 'clear' + suffix
            presence = bool(re.search(r'public var ' + has + r': Bool\b', swift_body))
            if presence and not re.search(r'public mutating func ' + clear + r'\(\)', swift_body):
                raise ValueError(f'{name}.{field}: has property without clear method')
            parsed[field] = dict(name=field, number=int(number), kind=kind,
                cardinality=(cardinality or '').strip(), comments=comments,
                required='// Required:' in comments, prop=prop, escaped=escaped,
                native=native, has=has, clear=clear, suffix=suffix, presence=presence)
        model[name] = dict(name=name, full_name=full_name, fields=parsed, oneof=bool(oneof))
    return model, enums
