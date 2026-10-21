// AI Scene Package file models (docs/AI_SCENE_PACKAGE.md). Field names follow the JSON keys.
// Engine-free: compiled by Unity (AIScene.Core, no engine references) and by unity/CoreTests (dotnet).
using System.Collections.Generic;
using System.IO;
using Newtonsoft.Json;

namespace AIScene.Core
{
    public sealed class Manifest
    {
        public string schema_version, package_id, route, environment;
        public double total_length_m, tile_m;
        public Dictionary<string, LayerRecord> layers;
        public List<TileRecord> tiles;
    }

    public sealed class LayerRecord
    {
        public string status;
        public List<string> files;
    }

    public sealed class TileRecord
    {
        public string id;
        public double from_s, to_s;
        public BoundsRecord bounds;
        public double[] origin;
        public Dictionary<string, string> files;
    }

    public sealed class BoundsRecord
    {
        public double[] min, max;
    }

    public sealed class RouteFile
    {
        public string route_id, version;
        public double total_length_m, sample_interval_m;
        public bool closed;
        public CoordinateSystem coordinate_system;
        public Marker start, finish;
        public List<Marker> checkpoints;
        public List<SectionRecord> sections;
        public RouteSamples samples;
    }

    public sealed class CoordinateSystem
    {
        public string handedness, up, east, north, elevation_reference;
        public double elevation_datum_m;
    }

    public sealed class Marker
    {
        public string id, name;
        public double s;
        public double[] position;
    }

    public sealed class SectionRecord
    {
        public string id, type;
        public double from_s, to_s;
    }

    public sealed class RouteSamples
    {
        public double[] s, x, y, z, elevation_m, grade_percent, heading_deg, curvature, width_left_m, width_right_m;
        public string[] surface_type;
    }

    public sealed class VegetationTile
    {
        public string tile;
        public double from_s, to_s;
        public List<string> zone_refs;
        public List<VegetationGroup> groups;
    }

    public sealed class VegetationGroup
    {
        public string proto, category;
        public int count;
        public float[] data;              // px py pz qx qy qz qw sx sy sz per instance, package frame
        public double[] s, lateral_offset_m;
        public int[] zone;
    }

    public sealed class VegetationPrototypes
    {
        public List<string> categories;
        public Dictionary<string, double> clearance_m;
        public List<VegetationPrototype> prototypes;
    }

    public sealed class VegetationPrototype
    {
        public string id, category;
        public double[] height_m, scale;
        public double footprint_radius_m, min_spacing_m;
        public LodHints lod;
    }

    public sealed class LodHints
    {
        public double[] lod_distances_m;
        public double cull_distance_m, billboard_from_m;
    }

    public sealed class EnvironmentFile
    {
        public string route_id;
        public Distant distant;
        public Atmosphere atmosphere;
    }

    public sealed class Distant
    {
        public FollowAnchors anchors;
        public List<DistantTerrain> terrain;
        public List<WaterBody> water;
    }

    public sealed class FollowAnchors
    {
        public FollowRunner follow_runner;
    }

    public sealed class FollowRunner
    {
        public double[] s, pivot_y_offset_m, yaw_deg;
    }

    public sealed class DistantTerrain
    {
        public string id, kind, file, anchor;
    }

    public sealed class WaterBody
    {
        public string id, kind, anchor;
        public double level_offset_m;
        public WaterGeometry geometry;
        public Dictionary<string, object> appearance;
    }

    public sealed class WaterGeometry
    {
        public string type;
        public double[] size_m;
    }

    public sealed class Atmosphere
    {
        public Sun sun;
        public Sky sky;
        public Ambient ambient;
        public Fog fog;
    }

    public sealed class Sun
    {
        public double[] direction_to_sun, color_linear;
        public double elevation_deg, azimuth_deg, intensity_relative;
    }

    public sealed class Sky
    {
        public string type, file;
        public SunInImage sun_in_image;
        public double intensity_relative;
    }

    public sealed class SunInImage
    {
        public double u, elevation_deg;
    }

    public sealed class Ambient
    {
        public string source;
        public double intensity_relative;
    }

    public sealed class Fog
    {
        public double density_per_m;
        public double[] color_linear;
    }

    public static class Json
    {
        public static T Load<T>(string path) => JsonConvert.DeserializeObject<T>(File.ReadAllText(path));
    }
}
