// Radiance RGBE (.hdr) decoder for the package's sky (environment/sky.hdr): flat and new-style RLE scanlines.
using System;
using System.IO;
using System.Text;

namespace AIScene.Core
{
    public sealed class HdrImage
    {
        public int Width, Height;
        public float[] Rgb;   // linear RGB, row 0 = top

        public static HdrImage Read(string path) => Decode(File.ReadAllBytes(path));

        public static HdrImage Decode(byte[] b)
        {
            int p = 0;
            string Line()
            {
                int s = p;
                while (p < b.Length && b[p] != (byte)'\n') p++;
                return Encoding.ASCII.GetString(b, s, p++ - s);
            }
            if (!Line().StartsWith("#?")) throw new InvalidDataException("not a Radiance HDR file");
            while (Line().Length > 0) { }
            var res = Line().Split(' ');
            if (res.Length != 4 || res[0] != "-Y" || res[2] != "+X") throw new InvalidDataException("unsupported HDR orientation");
            var img = new HdrImage { Height = int.Parse(res[1]), Width = int.Parse(res[3]) };
            int w = img.Width;
            img.Rgb = new float[w * img.Height * 3];
            var line = new byte[w * 4];
            for (int y = 0; y < img.Height; y++)
            {
                if (w >= 8 && w < 32768 && b[p] == 2 && b[p + 1] == 2 && (b[p + 2] << 8 | b[p + 3]) == w)
                {
                    p += 4;
                    for (int c = 0; c < 4; c++)
                        for (int x = 0; x < w;)
                        {
                            int n = b[p++];
                            if (n > 128) { n -= 128; byte v = b[p++]; while (n-- > 0) line[(x++) * 4 + c] = v; }
                            else while (n-- > 0) line[(x++) * 4 + c] = b[p++];
                        }
                }
                else
                {
                    Buffer.BlockCopy(b, p, line, 0, w * 4);
                    p += w * 4;
                }
                for (int x = 0; x < w; x++)
                {
                    int e = line[x * 4 + 3];
                    float f = e == 0 ? 0f : (float)Math.Pow(2, e - 136);  // ldexp(1, e - (128 + 8))
                    int o = (y * w + x) * 3;
                    img.Rgb[o] = line[x * 4] * f;
                    img.Rgb[o + 1] = line[x * 4 + 1] * f;
                    img.Rgb[o + 2] = line[x * 4 + 2] * f;
                }
            }
            return img;
        }
    }
}
