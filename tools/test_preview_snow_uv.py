"""Preview snow mask must identify hollows without changing terrain geometry."""
import json
import tempfile
import unittest
from pathlib import Path
from tools import road_terrain as rt, build_preview_snow_uv as snow


class SnowUVTest(unittest.TestCase):
    def test_hollow_receives_mask_and_geometry_is_preserved(self):
        with tempfile.TemporaryDirectory() as tmp:
            pkg=Path(tmp)/'pkg';(pkg/'preview_far').mkdir(parents=True)
            pos=[]
            for z in range(-80,81,20):
                for x in range(-80,81,20): pos.append((float(x),2300.+.02*(x*x+z*z),float(z)))
            indices=[]
            for j in range(8):
                for i in range(8):
                    a=j*9+i;indices.extend([a,a+1,a+9,a+1,a+10,a+9])
            mesh={'name':'test','translation':[0,0,0],'attributes':{'POSITION':pos,'NORMAL':[(0,1,0)]*len(pos),'TEXCOORD_0':[(0,0)]*len(pos),'_ROUTE_S':[0.]*len(pos)},'primitives':[{'material':{'name':'terrain_ground','color':[.2,.3,.2],'roughness':.9},'indices':indices}]}
            file=pkg/'preview_far/far.glb';rt.write_glb(str(file),mesh);original=rt.read_glb(str(file))
            Path(str(pkg)+'.godot_preview.json').write_text(json.dumps({'distant_preview_meshes':['preview_far/far.glb']}))
            report=snow.build(pkg,pkg/'preview_far_snow');result=rt.read_glb(str(pkg/'preview_far_snow/far.glb'))
            self.assertEqual(report['mesh_geometry'],'positions, normals, original UVs, indices and translations unchanged')
            self.assertEqual(result['attributes']['POSITION'],original['attributes']['POSITION'])
            self.assertEqual(result['primitives'][0]['indices'],original['primitives'][0]['indices'])
            self.assertGreater(result['attributes']['TEXCOORD_1'][40][0],0.)
            self.assertNotIn('TEXCOORD_1',rt.read_glb(str(file))['attributes'])

if __name__=='__main__':unittest.main()
