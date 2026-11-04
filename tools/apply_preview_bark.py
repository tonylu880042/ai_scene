#!/usr/bin/env python3
"""Embed a licensed bark texture in copied preview GLBs; do not alter geometry."""
import argparse
import json
import struct
from pathlib import Path


def apply(path, image_path, tint=(.8, .8, .8)):
    path = Path(path)
    data = path.read_bytes()
    magic, version, _ = struct.unpack_from('<III', data, 0)
    if magic != 0x46546c67 or version != 2: raise ValueError(f'Not a GLB 2: {path}')
    json_len, json_type = struct.unpack_from('<II', data, 12)
    if json_type != 0x4e4f534a: raise ValueError('Missing JSON chunk')
    doc = json.loads(data[20:20+json_len])
    offset = 20+json_len
    bin_len, bin_type = struct.unpack_from('<II', data, offset)
    if bin_type != 0x004e4942: raise ValueError('Missing BIN chunk')
    binary = bytearray(data[offset+8:offset+8+bin_len])
    material = next((m for m in doc.get('materials', []) if m.get('name') == 'branches'), None)
    if material is None: raise ValueError(f'No branches material in {path}')
    pbr = material.setdefault('pbrMetallicRoughness', {})
    if 'baseColorTexture' in pbr: raise ValueError(f'Branches already textured: {path}')
    binary.extend(b'\0' * (-len(binary) % 4))
    texture_data = Path(image_path).read_bytes()
    view = len(doc['bufferViews'])
    doc['bufferViews'].append({'buffer':0,'byteOffset':len(binary),'byteLength':len(texture_data)})
    binary.extend(texture_data)
    images = doc.setdefault('images', [])
    image = len(images); images.append({'bufferView':view,'mimeType':'image/jpeg','name':'preview_pine_bark'})
    textures = doc.setdefault('textures', [])
    index = len(textures); textures.append({'source':image})
    pbr['baseColorTexture'] = {'index':index}
    pbr['baseColorFactor'] = [*tint,1.0]
    doc['buffers'][0]['byteLength'] = len(binary)
    encoded = json.dumps(doc,separators=(',',':')).encode(); encoded += b' ' * (-len(encoded) % 4)
    binary.extend(b'\0' * (-len(binary) % 4))
    total = 12+8+len(encoded)+8+len(binary)
    result = struct.pack('<III',0x46546c67,2,total)+struct.pack('<II',len(encoded),0x4e4f534a)+encoded+struct.pack('<II',len(binary),0x004e4942)+binary
    path.write_bytes(result)


def apply_package(package, config):
    package = Path(package)
    protos = json.loads((package/'vegetation/prototypes.json').read_text())['prototypes']
    selected = set(config['prototypes']); processed = set()
    for p in protos:
        if p['id'] not in selected: continue
        target = package/p['mesh_file']
        if target in processed: continue
        apply(target, config['texture'], config.get('tint',[.8,.8,.8])); processed.add(target)
    if not processed: raise ValueError('No preview prototypes were textured')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('package');parser.add_argument('config')
    args=parser.parse_args(); apply_package(args.package,json.loads(Path(args.config).read_text()))
