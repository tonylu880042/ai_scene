"""Coverage checks for projected South Tyrol WCS preview terrain."""
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from PIL import Image, TiffImagePlugin
from tools import projected_dtm as dtm


class ProjectedDTMTest(unittest.TestCase):
    def test_projection_known_zone_central_meridian(self):
        east, north = dtm.utm32(0, 9)
        self.assertAlmostEqual(east, 500000, places=3)
        self.assertAlmostEqual(north, 0, places=3)

    def test_valid_and_nodata_samples(self):
        with tempfile.TemporaryDirectory() as tmp:
            image = Image.new('F',(2,2));image.putdata([100,101,-9999,103])
            tags=TiffImagePlugin.ImageFileDirectory_v2()
            tags[34264]=(1.,0.,0.,500000.,0.,-1.,0.,2.,0.,0.,0.,0.,0.,0.,0.,1.)
            image.save(Path(tmp)/'500000_0.tif',tiffinfo=tags)
            sampler=dtm.SouthTyrolDTM(tmp,{'coordinate_system':{'origin':{'lat':0,'lon':9},'elevation_datum_m':10}})
            with patch.object(dtm,'utm32',return_value=(500000.25,1.75)):
                self.assertEqual(sampler.sample(0,0),90)
            with patch.object(dtm,'utm32',return_value=(500000.25,.75)):
                self.assertIsNone(sampler.sample(0,0))
            with patch.object(dtm,'utm32',return_value=(504000,0)):
                self.assertIsNone(sampler.sample(0,0))
            self.assertEqual((sampler.hits,sampler.missing),(1,2))
            with patch.object(dtm,'utm32',return_value=(500001.,1.)):
                self.assertIsNone(sampler.sample_bilinear(0,0))
            other=Path(tmp)/'other';other.mkdir()
            image.putdata([100,101,102,103]);image.save(other/'500000_0.tif',tiffinfo=tags)
            sampler2=dtm.SouthTyrolDTM(other,{'coordinate_system':{'origin':{'lat':0,'lon':9},'elevation_datum_m':10}})
            with patch.object(dtm,'utm32',return_value=(500001.,1.)):
                self.assertAlmostEqual(sampler2.sample_bilinear(0,0),91.5)

if __name__=='__main__': unittest.main()
