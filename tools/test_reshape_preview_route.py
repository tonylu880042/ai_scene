"""Preview bends must rebuild a physically self-consistent route."""
import unittest
from unittest.mock import patch
from tools import reshape_preview_route as reshape, route_model as rm


class DTM:
    def __init__(self,*args): self.datum=0.;self.hits=0;self.missing=0
    def sample_bilinear(self,x,z): self.hits+=1;return 100.-.03*z


class ReshapePreviewRouteTest(unittest.TestCase):
    def test_bend_recalculates_distance_grade_and_markers(self):
        s=list(range(301));route=rm.finalize({'route_id':'bend_test','sample_interval_m':1.,'coordinate_system':{'origin':{'lat':0.,'lon':9.,'altitude_m':0.},'elevation_reference':'msl'},'samples':{'s':s,'x':[0.]*301,'z':[-float(i) for i in s],'elevation_m':[100+.03*i for i in s],'width_left_m':[2.]*301,'width_right_m':[2.]*301,'surface_type':['gravel']*301},'source':{},'finish':{'id':'finish','s':300.},'sections':[{'id':'test','type':'test','from_s':0.,'to_s':300.}]})
        bends=[{'from_s':20.,'to_s':280.,'amplitude_m':12.}]
        with patch.object(reshape,'SouthTyrolDTM',DTM):out,report=reshape.reshape(route,bends,'unused')
        self.assertEqual(report['validation_errors'],[])
        self.assertEqual(rm.validate(out),[])
        self.assertGreater(out['total_length_m'],route['total_length_m'])
        self.assertGreater(report['max_lateral_shift_m'],5.)
        self.assertEqual(out['samples']['x'][0],0.)
        self.assertAlmostEqual(out['samples']['x'][-1],0.,places=3)
        self.assertAlmostEqual(out['finish']['s'],out['total_length_m'],places=3)
        s=out['samples'];grade,_,_=rm.derive(s['s'],s['x'],s['z'],s['elevation_m'])
        self.assertLess(max(abs(a-b) for a,b in zip(grade,s['grade_percent'])),.02)
        self.assertIn('not real GPS',out['source']['geometry'])

if __name__=='__main__':unittest.main()
