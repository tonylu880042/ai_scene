"""The preview bark patch must not change mesh data or existing foliage materials."""
import json
import struct
import tempfile
import unittest
from pathlib import Path
from tools import road_terrain as rt, apply_preview_bark as bark


def unpack(path):
    data=Path(path).read_bytes();size=struct.unpack_from('<I',data,12)[0]
    doc=json.loads(data[20:20+size]);at=20+size
    bin_size=struct.unpack_from('<I',data,at)[0]
    return doc,data[at+8:at+8+bin_size]


class PreviewBarkTest(unittest.TestCase):
    def test_embedded_bark_preserves_all_mesh_data(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);path=root/'tree.glb';image=root/'bark.jpg';image.write_bytes(b'\xff\xd8\xff\xd9')
            mesh={'name':'test','translation':[1,2,3],'attributes':{'POSITION':[(0,0,0),(1,0,0),(0,1,0)],'NORMAL':[(0,0,1)]*3,'TEXCOORD_0':[(0,0),(1,0),(0,1)]},'primitives':[{'material':{'name':'branches','color':[.2,.2,.2],'roughness':.9},'indices':[0,1,2]}]}
            rt.write_glb(str(path),mesh);before,before_bin=unpack(path)
            bark.apply(path,image,[.7,.6,.5]);after,after_bin=unpack(path)
            self.assertEqual(after['meshes'],before['meshes'])
            self.assertEqual(after['nodes'],before['nodes'])
            self.assertEqual(after['accessors'],before['accessors'])
            self.assertEqual(after_bin[:len(before_bin)],before_bin)
            self.assertEqual(after['materials'][0]['pbrMetallicRoughness']['baseColorFactor'],[.7,.6,.5,1.])
            self.assertEqual(after['images'][-1]['mimeType'],'image/jpeg')
            with self.assertRaisesRegex(ValueError,'already textured'): bark.apply(path,image)

if __name__=='__main__':unittest.main()
