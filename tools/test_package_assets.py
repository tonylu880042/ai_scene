"""Integrity checks for optional shared prototype mesh assets in packages."""
import json
import tempfile
import unittest
from unittest import mock
from pathlib import Path
from tools import validate_package as vp
from tools import build_package_assets as bpa
from tools import structures as stc

class PrototypeAssetTest(unittest.TestCase):
    def test_glb_library_asset_preserves_bytes_and_mit_notice(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d); pkg=root/'package'; src=root/'source'; src.mkdir()
            mesh=bpa.Mesh(); mesh.tri([(0,0,0),(1,0,0),(0,1,0)],(0.4,0.7,0.3))
            mesh.save(src/'tree.glb','tree')
            (src/'LICENSE').write_text('MIT notice for example tree\n')
            (pkg/'vegetation').mkdir(parents=True); (pkg/'structures').mkdir(); (pkg/'tiles/00').mkdir(parents=True)
            (pkg/'vegetation/prototypes.json').write_text(json.dumps({'prototypes':[{'id':'conifer_larch'}]}))
            (pkg/'structures/prototypes.json').write_text(json.dumps({'prototypes':[]}))
            (pkg/'tiles/00/vegetation.json').write_text(json.dumps({'groups':[{'proto':'conifer_larch'}]}))
            (pkg/'manifest.json').write_text('{}')
            bpa.build(pkg, {'conifer_larch':{'file':str(src/'tree.glb'),'scale':1,'license':'MIT',
                                               'license_file':str(src/'LICENSE'),'attribution':'Example creator'}})
            result=json.loads((pkg/'vegetation/prototypes.json').read_text())['prototypes'][0]
            self.assertEqual((pkg/result['mesh_file']).read_bytes(),(src/'tree.glb').read_bytes())
            self.assertEqual(result['source']['license'],'MIT')
            self.assertEqual((pkg/result['source']['license_file']).read_text(),(src/'LICENSE').read_text())
            self.assertNotIn('CC0 library assets',json.loads((pkg/'manifest.json').read_text())['prototype_assets']['source'])

    def test_glb_rejects_nonunit_scale_and_missing_mit_notice(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d); mesh=bpa.Mesh(); mesh.tri([(0,0,0),(1,0,0),(0,1,0)],(1,1,1));mesh.save(root/'tree.glb','tree')
            with self.assertRaisesRegex(ValueError,'scale'):
                bpa.copy_gltf_asset(root/'pkg',{'file':str(root/'tree.glb'),'scale':2})
            with self.assertRaisesRegex(ValueError,'license_file'):
                bpa.build_library_source(root/'pkg',{'license':'MIT','attribution':'Creator'},root/'tree.glb')

    def test_declared_prototype_mesh_must_exist(self):
        with tempfile.TemporaryDirectory() as d:
            pkg=Path(d);(pkg/'vegetation').mkdir()
            (pkg/'manifest.json').write_text(json.dumps({'layers':{},'tiles':[]}))
            (pkg/'vegetation/prototypes.json').write_text(json.dumps({'prototypes':[{'id':'tree','mesh_file':'assets/tree.glb'}]}))
            result=vp.validate(d)[-1]
            self.assertEqual(result[1],'INVALID')
            self.assertIn('assets/tree.glb',' '.join(result[2]))

    def test_s19_chapel_mesh_has_gable_cupola_and_access_ramp_extent(self):
        mesh=bpa.structure('rotary_chapel_gable',[5.9,8.0,14.9])
        xs=[p[0] for p in mesh.pos];ys=[p[1] for p in mesh.pos];zs=[p[2] for p in mesh.pos]
        self.assertAlmostEqual(min(ys),0.0,places=5)
        self.assertGreater(max(ys),7.4)  # cupola cross reaches above the pitched roof
        self.assertLessEqual(max(xs),2.95);self.assertGreaterEqual(min(xs),-2.95)
        self.assertLessEqual(max(zs),7.45);self.assertGreaterEqual(min(zs),-7.45)  # ramp rails fit the declared footprint
        # Actual gable triangles sit on the short Z ends, while the ridge/cupola run along the long axis.
        end_faces=[set(mesh.pos[i:i+3]) for i in range(0,len(mesh.pos),3)
                   if all(abs(p[2]-6.45)<1e-6 for p in mesh.pos[i:i+3])]
        self.assertIn({(-2.95,3.55,6.45),(0.0,5.45,6.45),(2.95,3.55,6.45)},end_faces)
        self.assertIn({(-2.95,3.55,-6.45),(0.0,5.45,-6.45),(2.95,3.55,-6.45)},
                      [set(mesh.pos[i:i+3]) for i in range(0,len(mesh.pos),3)
                       if all(abs(p[2]+6.45)<1e-6 for p in mesh.pos[i:i+3])])
        self.assertIn((0.0,5.45,6.45),mesh.pos);self.assertIn((0.0,5.45,-6.45),mesh.pos)
        chapel_body_half_w=(5.9-.16)/2
        glass=[mesh.pos[i] for i in mesh.groups[(.24,.39,.43)]]
        glass=[p for p in glass if abs(p[0])>chapel_body_half_w and 1.4<p[1]<2.9 and abs(p[2])<5.0]
        self.assertTrue(glass)  # glazing protrudes beyond the inset wall while remaining within the footprint.
        self.assertLessEqual(max(abs(p[0]) for p in glass),2.95)
        self.assertGreater(len(mesh.pos),900)  # siding, windows, louvers and ramp are explicit geometry

    def test_chapel_cupola_end_parameter_moves_only_roof_cupola(self):
        dims=[5.9,8.0,14.9]
        legacy=bpa.structure('rotary_chapel_gable',dims)
        default=bpa.structure('rotary_chapel_gable',dims,{})
        opposite=bpa.structure('rotary_chapel_gable',dims,{'cupola_end':'negative_z'})
        # Legacy/default output and all below-cupola geometry, including the ground-contact base,
        # remain identical. Only the elevated cupola assembly changes end.
        self.assertEqual(default.pos,legacy.pos)
        center=dims[2]*.27
        legacy_cupola=[p for p in legacy.pos if p[1]>=5.4 and abs(p[2]-center)<.78]
        opposite_cupola=[p for p in opposite.pos if p[1]>=5.4 and abs(p[2]+center)<.78]
        self.assertTrue(legacy_cupola);self.assertEqual(len(opposite_cupola),len(legacy_cupola))
        self.assertEqual(sorted(tuple(round(v,5) for v in (x,y,z-2*center))
                                  for x,y,z in legacy_cupola),
                         sorted(tuple(round(v,5) for v in p) for p in opposite_cupola))
        # Every vertex outside the cupola's local region remains exactly where authored.
        legacy_body=[p for p in legacy.pos if p not in legacy_cupola]
        opposite_body=[p for p in opposite.pos if p not in opposite_cupola]
        self.assertEqual(legacy_body,opposite_body)
        with self.assertRaisesRegex(ValueError,'cupola_end'):
            bpa.structure('rotary_chapel_gable',dims,{'cupola_end':'south'})

    def test_s19_sky_podium_uses_absolute_osm_min_height_interval(self):
        # OSM part is 10..40 m; this complete estimated podium object adds the base once, never 10+40.
        mesh=bpa.structure('sky_broadwater_podium',[46.1,40.16,62.3])
        xs=[p[0] for p in mesh.pos];ys=[p[1] for p in mesh.pos];zs=[p[2] for p in mesh.pos]
        self.assertAlmostEqual(min(ys),0.0,places=5)
        self.assertAlmostEqual(max(ys),40.16,places=2)
        self.assertLessEqual(max(xs),23.05);self.assertGreaterEqual(min(xs),-23.05)
        self.assertLessEqual(max(zs),31.15);self.assertGreaterEqual(min(zs),-31.15)
        # Balcony slabs visibly project beyond the inset body while staying in the declared footprint.
        body_front=(62.3-4.0)/2-2.0
        balcony_front=max(z for x,y,z in mesh.pos if 2.5<y<3.0 and z>body_front)
        self.assertGreater(balcony_front,body_front+2.0)
        self.assertLessEqual(balcony_front,31.15)
        # End-wall windows overlap the inset body and protrude past its end face, avoiding coplanar z-fighting.
        body_left=-(46.1-.4)/2
        window_x=[x for x,y,z in mesh.pos if 5.4<y<6.6 and x<0 and z>12.0]
        self.assertTrue(window_x)
        self.assertLess(min(window_x),body_left)
        self.assertGreater(max(window_x),body_left)
        self.assertGreater(len(mesh.pos),600)  # podium bands plus three staggered end-wall windows

    def test_replace_point_objects_preserves_fixed_target_and_rejects_nonpoint(self):
        with tempfile.TemporaryDirectory() as d:
            pkg=Path(d);(pkg/'route').mkdir();(pkg/'manifest.json').write_text('{}')
            for path,data in [('route/route.json',{}),('semantics/semantics.json',{}),
                              ('structures/structures.json',{'objects':[
                                  {'object_id':'st1','placement':'point'},
                                  {'object_id':'other','placement':'point','keep':True},
                                  {'object_id':'st2','placement':'linear'}]}),
                              ('structures/prototypes.json',{'prototypes':[]})]:
                p=pkg/path;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(data))
            hint={'object_id':'st1','semantic_type':'church','prototype':'rotary_chapel_gable',
                  'importance':'high','s':42.5,'lateral_offset_m':-8.0,'dimensions_m':[5.9,8,14.9],
                  'source':{'kind':'test'}}
            captured={}
            with mock.patch.object(stc,'Site') as site_cls, \
                 mock.patch.object(stc,'_point',return_value={'object_id':'st1','placement':'point'}) as point, \
                 mock.patch.object(stc,'_finish'), mock.patch.object(stc,'_write',side_effect=lambda *a:captured.update(objs=a[3],protos=a[4])):
                site_cls.return_value.problems.return_value=['tree conflict']
                # Exact authored anchor is passed through; no fit-based slide is possible in this helper.
                stc.replace_point_objects(str(pkg),[hint])
            self.assertEqual(point.call_args.args[5:7],(42.5,-8.0))
            self.assertEqual(captured['objs'][1],{'object_id':'other','placement':'point','keep':True})
            self.assertEqual(captured['objs'][2],{'object_id':'st2','placement':'linear'})
            with self.assertRaisesRegex(ValueError,'not a point object'):
                with mock.patch.object(stc,'Site'):
                    objs=json.loads((pkg/'structures/structures.json').read_text());objs['objects'][0]['placement']='linear'
                    (pkg/'structures/structures.json').write_text(json.dumps(objs))
                    stc.replace_point_objects(str(pkg),[hint])

    def test_blocked_acceptance_cannot_be_reported_as_complete(self):
        with tempfile.TemporaryDirectory() as d:
            pkg=Path(d)
            (pkg/'manifest.json').write_text(json.dumps({'layers':{},'tiles':[], 'acceptance':'acceptance.json'}))
            (pkg/'acceptance.json').write_text(json.dumps({'status':'blocked','blockers':[{'reason':'terrain hides road'}]}))
            result=vp.validate(d)[-1]
            self.assertEqual(result, ('acceptance','INVALID',['terrain hides road']))
