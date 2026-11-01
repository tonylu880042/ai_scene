"""Small stdlib glTF reader for triangle positions used by structure support validation."""
import base64
import json
import math
import os
import struct
import urllib.parse


class GltfMeshError(ValueError):
    pass


_COMPONENTS = {5120: ("b", 1), 5121: ("B", 1), 5122: ("h", 2), 5123: ("H", 2),
               5125: ("I", 4), 5126: ("f", 4)}
_WIDTHS = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT2": 4, "MAT3": 9, "MAT4": 16}


def _node_matrix(node):
    if "matrix" in node:
        return node["matrix"]
    t = node.get("translation", [0, 0, 0])
    x, y, z, w = node.get("rotation", [0, 0, 0, 1])
    sx, sy, sz = node.get("scale", [1, 1, 1])
    return [(1-2*(y*y+z*z))*sx, (2*(x*y+z*w))*sx, (2*(x*z-y*w))*sx, 0,
            (2*(x*y-z*w))*sy, (1-2*(x*x+z*z))*sy, (2*(y*z+x*w))*sy, 0,
            (2*(x*z+y*w))*sz, (2*(y*z-x*w))*sz, (1-2*(x*x+y*y))*sz, 0,
            *t, 1]


def _mul(a, b):
    return [sum(a[k*4+r] * b[c*4+k] for k in range(4)) for c in range(4) for r in range(4)]


def _decode_accessor(doc, buffers, accessor_index):
    try:
        acc = doc["accessors"][accessor_index]
        if "sparse" in acc:
            raise GltfMeshError("sparse accessors are not supported for structure meshes")
        view = doc["bufferViews"][acc["bufferView"]]
        fmt, component_size = _COMPONENTS[acc["componentType"]]
        width = _WIDTHS[acc["type"]]
        stride = view.get("byteStride", component_size * width)
        start = view.get("byteOffset", 0) + acc.get("byteOffset", 0)
        buf = buffers[view["buffer"]]
        if view.get("byteOffset", 0) + view["byteLength"] > len(buf):
            raise GltfMeshError("bufferView exceeds buffer bounds")
        count = acc["count"]
        if stride < component_size * width:
            raise GltfMeshError("accessor byteStride is too small")
        if count < 0 or acc.get("byteOffset", 0) + max(0, count - 1) * stride + component_size * width > view["byteLength"]:
            raise GltfMeshError("accessor exceeds its bufferView bounds")
        out = []
        for i in range(count):
            off = start + i * stride
            if off + component_size * width > len(buf):
                raise GltfMeshError("accessor exceeds buffer bounds")
            vals = struct.unpack_from("<" + fmt * width, buf, off)
            if acc.get("normalized") and acc["componentType"] != 5126:
                signed = acc["componentType"] in (5120, 5122)
                maximum = {1: 127 if signed else 255, 2: 32767 if signed else 65535,
                           4: 2147483647 if signed else 4294967295}[component_size]
                vals = tuple(max(-1.0, v / maximum) if signed else v / maximum for v in vals)
            out.append(vals[0] if width == 1 else vals)
        return out
    except (KeyError, IndexError, TypeError, struct.error) as exc:
        raise GltfMeshError(f"invalid glTF accessor: {exc}") from exc


def read(path):
    """Return transformed vertices and primitive indices; reject unsupported or malformed assets clearly."""
    path = os.path.abspath(path)
    try:
        is_glb = path.lower().endswith(".glb")
        if not is_glb and not path.lower().endswith(".gltf"):
            raise GltfMeshError("expected .glb or .gltf asset")
        binary_chunk = None
        if is_glb:
            with open(path, "rb") as gf:
                raw_glb = gf.read()
            if len(raw_glb) < 20:
                raise GltfMeshError("GLB header is truncated")
            magic, version, total_length = struct.unpack_from("<III", raw_glb)
            if magic != 0x46546C67 or version != 2 or total_length != len(raw_glb):
                raise GltfMeshError("invalid GLB 2.0 header or declared length")
            offset = 12; json_bytes = None
            while offset < len(raw_glb):
                if offset + 8 > len(raw_glb):
                    raise GltfMeshError("truncated GLB chunk header")
                chunk_length, chunk_type = struct.unpack_from("<II", raw_glb, offset); offset += 8
                if offset + chunk_length > len(raw_glb):
                    raise GltfMeshError("GLB chunk exceeds file bounds")
                chunk = raw_glb[offset:offset + chunk_length]; offset += chunk_length
                if chunk_type == 0x4E4F534A and json_bytes is None:
                    json_bytes = chunk
                elif chunk_type == 0x004E4942 and binary_chunk is None:
                    binary_chunk = chunk
            if json_bytes is None:
                raise GltfMeshError("GLB has no JSON chunk")
            doc = json.loads(json_bytes.decode("utf-8").rstrip(" \t\r\n\0"))
        else:
            with open(path, encoding="utf-8") as f:
                doc = json.load(f)
        if doc.get("asset", {}).get("version") != "2.0":
            raise GltfMeshError("asset is not glTF 2.0")
        if doc.get("extensionsRequired"):
            raise GltfMeshError("unsupported required glTF extensions: " + ", ".join(doc["extensionsRequired"]))
        buffers = []
        for buffer_index, buffer in enumerate(doc.get("buffers", [])):
            uri = buffer.get("uri")
            if not uri:
                if is_glb and buffer_index == 0 and binary_chunk is not None:
                    raw = binary_chunk
                else:
                    raise GltfMeshError("buffer is missing its URI or GLB BIN chunk")
            elif uri.startswith("data:"):
                header, payload = uri.split(",", 1)
                raw = base64.b64decode(payload) if ";base64" in header else urllib.parse.unquote_to_bytes(payload)
            else:
                with open(os.path.join(os.path.dirname(path), urllib.parse.unquote(uri)), "rb") as bf:
                    raw = bf.read()
            if len(raw) < buffer["byteLength"]:
                raise GltfMeshError("buffer is shorter than declared byteLength")
            buffers.append(raw)
        scene_index = doc.get("scene", 0)
        scene_nodes = doc.get("scenes", [{}])[scene_index].get("nodes", list(range(len(doc.get("nodes", [])))))
        vertices, indices = [], []

        visiting = set()
        def visit(node_index, parent):
            if node_index in visiting:
                raise GltfMeshError("node hierarchy contains a cycle")
            visiting.add(node_index)
            node = doc["nodes"][node_index]
            matrix = _mul(parent, _node_matrix(node))
            if "mesh" in node:
                for primitive in doc["meshes"][node["mesh"]].get("primitives", []):
                    if primitive.get("mode", 4) != 4:
                        raise GltfMeshError("only triangle primitives are supported")
                    positions = _decode_accessor(doc, buffers, primitive["attributes"]["POSITION"])
                    offset = len(vertices)
                    for x, y, z in positions:
                        p = (matrix[0]*x+matrix[4]*y+matrix[8]*z+matrix[12],
                             matrix[1]*x+matrix[5]*y+matrix[9]*z+matrix[13],
                             matrix[2]*x+matrix[6]*y+matrix[10]*z+matrix[14])
                        if not all(math.isfinite(v) for v in p):
                            raise GltfMeshError("mesh has non-finite POSITION")
                        vertices.append(p)
                    if "indices" in primitive:
                        index_accessor = doc["accessors"][primitive["indices"]]
                        if (index_accessor["type"] != "SCALAR"
                                or index_accessor["componentType"] not in (5121, 5123, 5125)
                                or index_accessor.get("normalized")):
                            raise GltfMeshError("indices must use an unsigned integer SCALAR accessor")
                        decoded_indices = _decode_accessor(doc, buffers, primitive["indices"])
                        if any(not isinstance(i, int) or i < 0 or i >= len(positions) for i in decoded_indices):
                            raise GltfMeshError("primitive index is outside its POSITION accessor bounds")
                        indices.extend(offset + int(i) for i in decoded_indices)
                    else:
                        indices.extend(offset + i for i in range(len(positions)))
            for child in node.get("children", []):
                visit(child, matrix)
            visiting.remove(node_index)

        for node in scene_nodes:
            visit(node, [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])
        if not vertices:
            raise GltfMeshError("asset contains no POSITION vertices")
        if len(indices) % 3:
            raise GltfMeshError("triangle index count is not divisible by three")
        if any(not isinstance(i, int) or i < 0 or i >= len(vertices) for i in indices):
            raise GltfMeshError("mesh index is negative or outside POSITION bounds")
        return vertices, indices
    except GltfMeshError:
        raise
    except (OSError, json.JSONDecodeError, KeyError, IndexError, TypeError, ValueError, struct.error) as exc:
        raise GltfMeshError(f"cannot read glTF mesh {path}: {exc}") from exc
