"""Checks make_icon.py against the icon spec: python3 -m unittest design/icon/test_make_icon.py"""
import colorsys
import importlib.util
import os
import unittest

spec = importlib.util.spec_from_file_location("make_icon", os.path.join(os.path.dirname(__file__), "make_icon.py"))
make_icon = importlib.util.module_from_spec(spec)
spec.loader.exec_module(make_icon)


def hsl_hex(h, s, l):
    r, g, b = colorsys.hls_to_rgb(h / 360, l / 100, s / 100)
    return "#{:02X}{:02X}{:02X}".format(*(round(c * 255) for c in (r, g, b)))


class IconSpecTests(unittest.TestCase):
    def test_wedge_is_fusion_accent_in_both_appearances(self):
        self.assertEqual(make_icon.LIGHT["wedge"], hsl_hex(16, 88, 57))
        self.assertEqual(make_icon.DARK["wedge"], hsl_hex(16, 85, 56))

    def test_ring_hole_is_a_third_of_the_outer_radius(self):
        self.assertAlmostEqual(make_icon.R_IN, make_icon.R_OUT / 3)

    def test_wedge_spans_56_degrees(self):
        self.assertAlmostEqual(make_icon.WEDGE[1] - make_icon.WEDGE[0], 56)


if __name__ == "__main__":
    unittest.main()
