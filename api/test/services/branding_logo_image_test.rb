# frozen_string_literal: true

require "test_helper"

class BrandingLogoImageTest < ActiveSupport::TestCase
  test "valid PNGs are rewritten without metadata or animation chunks" do
    bytes = png(extra: chunk("tEXt", "private metadata") + chunk("acTL", [ 2, 0 ].pack("N2")))
    safe = read(bytes)
    assert_equal png, safe
    assert_not_includes safe, "private metadata"
  end

  test "indexed PNGs retain their palette and transparency" do
    palette = chunk("PLTE", "\xff\x00\x00".b) + chunk("tRNS", "\x80".b)
    bytes = png(color: 3, extra: palette, pixels: "\x00\x00".b)
    assert_equal bytes, read(bytes)
  end

  test "empty missing wrong MIME and spoofed PNG uploads are rejected" do
    assert_raises(Branding::LogoImage::Invalid) { Branding::LogoImage.read!(nil) }
    assert_raises(Branding::LogoImage::Invalid) { read(png, mime: "image/svg+xml") }
    [ "", "<svg onload='alert(1)'/>", "<html>logo</html>", "\xff\xd8\xff".b ].each do |bytes|
      assert_raises(Branding::LogoImage::Invalid) { read(bytes) }
    end
  end

  test "size dimensions interlace and bit depth are bounded" do
    [ "x" * (Branding::LogoImage::MAX_BYTES + 1), png(width: 2049), png(height: 0), png(interlace: 1), png(depth: 3) ].each do |bytes|
      assert_raises(Branding::LogoImage::Invalid) { read(bytes) }
    end
  end

  test "truncation CRC errors trailing bytes invalid filters and decompression bombs are rejected" do
    broken_crc = png.dup
    broken_crc.setbyte(29, broken_crc.getbyte(29) ^ 1)
    [ png[0...-1], broken_crc, png + "<script/>", png(pixels: "\x05\x00\x00\x00\xff".b),
      png(pixels: "\x00" * 1_000_000), png(pixels: "\x00"), png(compressed: "not zlib"),
      png(compressed: Zlib::Deflate.deflate("\x00\x00\x00\x00\xff".b) + "extra") ].each do |bytes|
      assert_raises(Branding::LogoImage::Invalid) { read(bytes) }
    end
  end

  test "duplicate headers missing palette and unknown critical chunks are rejected" do
    [ png(extra: chunk("IHDR", [ 1, 1, 8, 6, 0, 0, 0 ].pack("NNC5"))),
      png(color: 3, pixels: "\x00\x00".b), png(extra: chunk("NOPE", "")) ].each do |bytes|
      assert_raises(Branding::LogoImage::Invalid) { read(bytes) }
    end
  end

  test "whitespace IDAT data counts toward ordering and cannot be followed by another IDAT after metadata" do
    bytes = Branding::LogoImage::SIGNATURE + chunk("IHDR", [ 1, 1, 8, 6, 0, 0, 0 ].pack("NNC5")) +
      chunk("IDAT", " ") + chunk("tEXt", "metadata") + chunk("IDAT", Zlib::Deflate.deflate("\x00\x00\x00\x00\xff".b)) + chunk("IEND", "".b)
    assert_raises(Branding::LogoImage::Invalid) { read(bytes) }
  end

  private

  def read(bytes, mime: "image/png")
    file = Tempfile.new([ "logo", ".png" ], binmode: true)
    file.write(bytes); file.rewind
    Branding::LogoImage.read!(ActionDispatch::Http::UploadedFile.new(tempfile: file, filename: "logo.png", type: mime))
  ensure
    file&.close!
  end

  def png(width: 1, height: 1, depth: 8, color: 6, interlace: 0, pixels: "\x00\x00\x00\x00\xff".b, extra: "".b, compressed: nil)
    Branding::LogoImage::SIGNATURE + chunk("IHDR", [ width, height, depth, color, 0, 0, interlace ].pack("NNC5")) +
      extra + chunk("IDAT", compressed || Zlib::Deflate.deflate(pixels)) + chunk("IEND", "".b)
  end

  def chunk(type, bytes)
    [ bytes.bytesize ].pack("N") + type + bytes + [ Zlib.crc32(type + bytes) ].pack("N")
  end
end
