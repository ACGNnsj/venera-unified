# AVIF fixtures

These unmodified samples come from [AOMediaCodec/libavif](https://github.com/AOMediaCodec/libavif/tree/b70519419573c958adc1bf94176ca0bf496e88e2/tests/data), pinned at commit `b70519419573c958adc1bf94176ca0bf496e88e2`. Each sample is explicitly listed as licensed under the same license as libavif in the [upstream fixture README](https://github.com/AOMediaCodec/libavif/blob/b70519419573c958adc1bf94176ca0bf496e88e2/tests/data/README.md). The BSD 2-Clause copyright and license notice is preserved in [LICENSE](LICENSE).

The samples cover a static pixel, an animated sequence, animation with alpha/Exif/XMP, and alpha with rotation. They are used for format recognition and optional codec probes; recognition does not imply that every platform can decode them.

The last two rows are **locally generated** rather than upstream, to cover the gaps the upstream set leaves (12-bit depth, large page):

- `e_12bit_hdr.avif` — 96x64, encoded at `--depth 12` with libavif `avifenc` 1.4.2 (aom encoder), qcolor 100. Exercises the high-bit-depth decode path.
- `f_large_page.avif` — 3000x4200 (12.6 MP), encoded at qcolor 45 / speed 10, 50 KB. Exercises the large-page decode path and its memory cost.

Both were produced from synthetic content authored in this repository, so no third-party license applies to them.

| File | Bytes | SHA-256 |
|---|---:|---|
| `white_1x1.avif` | 305 | `ea4e43d1f07e4c00de16c13afa32376111bb306e51f08212cf4c1b6064df3667` |
| `colors-animated-8bpc.avif` | 1235 | `2f8683d21725261f37f86e115f0c212cc52d0fefd3a2ddfcc4fa648c1859906d` |
| `colors-animated-8bpc-alpha-exif-xmp.avif` | 7506 | `c2e38681057c15009c4b76ea08cea68cdde80806abd41d42a646f697bf5aabb2` |
| `abc_color_irot_alpha_irot.avif` | 10597 | `b371cc88244a873131e4d10ff9363d71ce4f41cf333bd4a491b38d970d9abd3b` |
| `e_12bit_hdr.avif` (local) | 12736 | `6d449dbdde6cc925b6827b29cd3274ef899aba08801ec174e07ae6060b7eaaa4` |
| `f_large_page.avif` (local) | 50106 | `d82e8c79d3d95efb04559d1f47f581a65c592fe0ff822a53d8e069f47e29869d` |
