// Distance-based tile streaming plan, vegetation LOD choice and a spatial grid for culling. Engine-free.
using System;
using System.Collections.Generic;

namespace AIScene.Core
{
    public static class TileStreaming
    {
        /// <summary>Tiles that should be resident when the player is at s: everything overlapping [s - behind, s + ahead].</summary>
        public static HashSet<string> Wanted(IReadOnlyList<TileRecord> tiles, double s, double ahead, double behind)
        {
            var set = new HashSet<string>();
            foreach (var t in tiles)
                if (t.to_s >= s - behind && t.from_s <= s + ahead) set.Add(t.id);
            return set;
        }

        /// <summary>The tile the player stands in (from_s <= s < to_s; the last tile includes its end).</summary>
        public static TileRecord At(IReadOnlyList<TileRecord> tiles, double s)
        {
            for (int i = 0; i < tiles.Count; i++)
                if (s >= tiles[i].from_s && (s < tiles[i].to_s || i == tiles.Count - 1)) return tiles[i];
            return tiles.Count > 0 ? tiles[0] : null;
        }
    }

    public static class Lod
    {
        /// <summary>LOD level for a prototype at a camera distance: 0 .. lod_distances.Length, or -1 when culled.</summary>
        public static int Level(VegetationPrototype p, double distance)
        {
            double cull = p.lod != null && p.lod.cull_distance_m > 0 ? p.lod.cull_distance_m : 300.0;
            if (distance > cull) return -1;
            var d = p.lod?.lod_distances_m;
            if (d == null) return 0;
            for (int i = 0; i < d.Length; i++)
                if (distance <= d[i]) return i;
            return d.Length;
        }
    }

    /// <summary>Instances bucketed into square cells (horizontal x / z) so a renderer culls cells, not instances.</summary>
    public sealed class InstanceGrid
    {
        public readonly double CellSize;
        public readonly Dictionary<(int, int), List<int>> Cells = new Dictionary<(int, int), List<int>>();

        public InstanceGrid(IReadOnlyList<Vec3> points, double cellSize)
        {
            CellSize = cellSize;
            for (int i = 0; i < points.Count; i++)
            {
                var key = ((int)Math.Floor(points[i].X / cellSize), (int)Math.Floor(points[i].Z / cellSize));
                if (!Cells.TryGetValue(key, out var list)) Cells[key] = list = new List<int>();
                list.Add(i);
            }
        }

        public Vec3 CellCentre((int, int) key, double y) => new Vec3((key.Item1 + 0.5) * CellSize, y, (key.Item2 + 0.5) * CellSize);
    }
}
