import Foundation
import Testing

@testable import FmEe2eCore

@Test("GNU・BusyBox の tar -tv の出力を読む")
func readGnuTarListing() {
  let items = parseGnuTarListing(
    "drwxr-xr-x nacci/nacci         0 2026-10-29 09:00 ./sub dir/\n"
      + "-rw-r--r-- nacci/nacci      1234 2026-10-29 09:01 ./sub dir/a'b $c.txt\n"
      + "lrwxrwxrwx nacci/nacci         0 2026-10-29 09:02 link -> sub dir\n"
      + "hrw-r--r-- nacci/nacci         0 2026-10-29 09:03 hard link to -dash.txt\n"
      // BusyBox は秒まで出す。
      + "-rw-r--r-- 1000/1000          5 2026-10-28 23:59:59 日本語.txt\n"
      + "tar: 余計な行\n"
  )
  #expect(items.map(\.path) == ["sub dir", "sub dir/a'b $c.txt", "link", "hard", "日本語.txt"])
  #expect(items.map(\.isDir) == [true, false, false, false, false])
  #expect(items.map(\.size) == [0, 1234, 0, 0, 5])
  #expect(items[1].raw == "./sub dir/a'b $c.txt")
  #expect(items[1].modified == localDateTime(2026, 10, 29, 9, 1))
  #expect(items[4].modified == localDateTime(2026, 10, 28, 23, 59))
}

@Test("unzip -Z -l -T（zipinfo）の出力を読む")
func readZipinfoListing() {
  let items = parseZipinfoListing(
    "Archive:  /home/nacci/x.zip\n"
      + "Zip file size: 480 bytes, number of entries: 3\n"
      + "drwxr-xr-x  3.0 unx        0 bx        0 stor 20261029.101703 sub dir/\n"
      + "-rw-r--r--  3.0 unx        2 tx        2 stor 20261029.101703 sub dir/a'b $c.txt\n"
      // Windows で作った zip。
      + "-rw-a--     2.0 fat     1234 b-      567 defN 20250101.000000 -dash.txt\n"
      + "3 files, 1236 bytes uncompressed, 569 bytes compressed:  54.0%\n"
  )
  #expect(items.map(\.path) == ["sub dir", "sub dir/a'b $c.txt", "-dash.txt"])
  #expect(items.map(\.isDir) == [true, false, false])
  #expect(items.map(\.size) == [0, 2, 1234])
  #expect(items[0].modified == localDateTime(2026, 10, 29, 10, 17))
}
