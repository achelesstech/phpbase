<?php
// Imagick and GD under /etc/ImageMagick-7/policy.xml (spec §7.8), asserted by
// test/runtime/45-imagemagick.sh. ?case=<name> prints "<name>:<result>" lines;
// list cases print one "<name>.<item>:<result>" line per item. Everything it
// writes goes under /tmp/imagick-test.
header('Content-Type: text/plain');

$dir = '/tmp/imagick-test';
if (!is_dir($dir)) {
    mkdir($dir, 0700);
}

function result(string $name, string $value): void
{
    printf("%s:%s\n", $name, str_replace("\n", ' ', $value));
}

function png_chunk(string $type, string $data): string
{
    return pack('N', strlen($data)) . $type . $data . pack('N', crc32($type . $data));
}

// A PNG whose header declares $w x $h but carries only $rows rows of pixels.
// ImageMagick sizes the pixel cache, and so applies the resource limits, from
// the header before it decodes a single row, so the file can stay small.
function png_stub(int $w, int $h, int $rows = 8): string
{
    $raw = str_repeat("\0" . str_repeat("\0", $w * 3), $rows);   // filter byte + RGB zeros
    return "\x89PNG\r\n\x1a\n"
        . png_chunk('IHDR', pack('NNCCCCC', $w, $h, 8, 2, 0, 0, 0))
        . png_chunk('IDAT', gzcompress($raw, 1))
        . png_chunk('IEND', '');
}

// A GIF declaring $w x $h with no usable pixel data, for the same reason.
function gif_stub(int $w, int $h): string
{
    return 'GIF89a' . pack('vv', $w, $h) . "\0\0\0"        // logical screen, no palette
        . "\x2c" . pack('vvvv', 0, 0, $w, $h) . "\0"        // image descriptor
        . "\x02\x02\x44\x01\0\x3b";                         // LZW min code size, one block, trailer
}

function dims(Imagick $im): string
{
    return sprintf('%s %dx%d', $im->getImageFormat(), $im->getImageWidth(), $im->getImageHeight());
}

switch ($_GET['case'] ?? '') {
    case 'roundtrip':
        foreach (['JPEG' => 'jpg', 'PNG' => 'png', 'GIF' => 'gif', 'WEBP' => 'webp', 'AVIF' => 'avif', 'BMP' => 'bmp', 'ICO' => 'ico'] as $format => $ext) {
            try {
                $im = new Imagick();
                $im->newImage(64, 64, '#c85028');
                $im->setImageFormat($format);
                $im->writeImage("$dir/roundtrip.$ext");
                $back = new Imagick("$dir/roundtrip.$ext");
                result("roundtrip.$format", dims($back) === "$format 64x64" ? 'ok' : dims($back));
            } catch (Throwable $e) {
                result("roundtrip.$format", $e->getMessage());
            }
        }
        // HEIC is read-only on this image: Alpine's libheif decodes HEVC
        // (libde265) but has no encoder. A committed 64x64 HEIC (heif-enc,
        // x265) stands in for the write half.
        try {
            $back = new Imagick(__DIR__ . '/sample-64x64.heic');
            result('roundtrip.HEIC', dims($back) === 'HEIC 64x64' ? 'ok' : dims($back));
        } catch (Throwable $e) {
            result('roundtrip.HEIC', $e->getMessage());
        }
        break;

    case 'blocked':
        file_put_contents("$dir/in.svg", '<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><rect width="8" height="8" fill="red"/></svg>');
        file_put_contents("$dir/in.mvg", "viewbox 0 0 8 8\nfill red\nrectangle 0,0 8,8\n");
        file_put_contents("$dir/in.msl", '<?xml version="1.0"?><image size="8x8"><read filename="xc:red"/></image>');
        file_put_contents("$dir/in.txt", "hello\n");
        $png = new Imagick();
        $png->newImage(8, 8, 'red');
        $png->setImageFormat('PNG');
        $png->writeImage("$dir/in.png");
        $sources = [
            'msl'       => "msl:$dir/in.msl",
            'mvg'       => "mvg:$dir/in.mvg",
            'svg'       => "svg:$dir/in.svg",
            'msvg'      => "msvg:$dir/in.svg",
            // ImageMagick's prefix form. A full https://… URL never reaches
            // ImageMagick: Imagick fetches it with PHP streams, so
            // allow_url_fopen governs that path, not the policy.
            'https'     => "https:$dir/in.png",
            'text'      => "text:$dir/in.txt",
            'ps'        => "ps:$dir/in.txt",
            'eps'       => "eps:$dir/in.txt",
            'pdf'       => "pdf:$dir/in.txt",
            'xps'       => "xps:$dir/in.txt",
            'ephemeral' => "ephemeral:$dir/in.png",
            'label'     => 'label:hello',
        ];
        foreach ($sources as $name => $source) {
            try {
                $im = new Imagick();
                $im->readImage($source);
                // This ImageMagick has no EPHEMERAL coder (Alpine ships none),
                // so the prefix is an unknown format name: the file is read by
                // its magic bytes, through the allowlist, and is NOT deleted.
                if ($name === 'ephemeral' && file_exists("$dir/in.png")) {
                    result("blocked.$name", 'inert');
                } else {
                    result("blocked.$name", 'read ' . $im->getImageFormat());
                }
            } catch (Throwable $e) {
                // "no decode delegate": the coder is not installed at all
                // (SVG, PS, EPS and PDF are in Alpine's imagemagick-svg and
                // imagemagick-pdf, which the image does not have), which
                // refuses the format just as well.
                $m = $e->getMessage();
                result("blocked.$name", preg_match('/security policy|no decode delegate/', $m) ? 'refused' : $m);
            }
        }
        break;

    case 'photo24':
        $gd = imagecreatetruecolor(6000, 4000);
        imagefilledrectangle($gd, 0, 0, 5999, 3999, imagecolorallocate($gd, 200, 80, 40));
        imagejpeg($gd, "$dir/photo24.jpg", 85);
        imagedestroy($gd);
        try {
            $im = new Imagick("$dir/photo24.jpg");
            $im->thumbnailImage(400, 0);
            result('photo24', $im->getImageWidth() === 400 ? 'ok' : dims($im));
        } catch (Throwable $e) {
            result('photo24', $e->getMessage());
        }
        break;

    case 'wide':
        // The GIF reaches ImageMagick's own check, which names the limit. The
        // PNG coder hands the limits to libpng (png_set_user_limits), which
        // refuses the header first, as "Invalid IHDR data".
        file_put_contents("$dir/wide.png", png_stub(20000, 20000));
        file_put_contents("$dir/wide.gif", gif_stub(20000, 20000));
        foreach (['png', 'gif'] as $ext) {
            try {
                $im = new Imagick("$dir/wide.$ext");
                result("wide.$ext", 'read ' . dims($im));
            } catch (Throwable $e) {
                result("wide.$ext", $e->getMessage());
            }
        }
        break;

    case 'bomb16k':
        file_put_contents("$dir/bomb16k.png", png_stub(16384, 16384));
        try {
            $im = new Imagick("$dir/bomb16k.png");
            result('bomb16k', 'read ' . dims($im));
        } catch (Throwable $e) {
            result('bomb16k', $e->getMessage());
        }
        break;

    case 'gd':
        $gd = imagecreatetruecolor(6000, 4000);
        result('gd', $gd !== false ? 'ok' : 'imagecreatetruecolor(6000, 4000) failed');
        break;

    default:
        http_response_code(400);
        echo "usage: imagick.php?case=roundtrip|blocked|photo24|wide|bomb16k|gd\n";
}
