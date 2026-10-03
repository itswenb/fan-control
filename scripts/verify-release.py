#!/usr/bin/env python3
"""检查发布配置和更新认证；只处理本地文件，不启动应用或访问硬件。"""
import base64
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

version, key_file, archive_name, feed_name, tool_name, app_name = sys.argv[1:]
archive, feed = pathlib.Path(archive_name), pathlib.Path(feed_name)
with (pathlib.Path(app_name) / "Contents/Info.plist").open("rb") as stream:
    info = plistlib.load(stream)
assert info["CFBundleVersion"] == info["CFBundleShortVersionString"] == version
assert len(base64.b64decode(info["SUPublicEDKey"], validate=True)) == 32
assert info["SUFeedURL"] == "https://github.com/itswenb/fan-control/releases/latest/download/appcast.xml"
assert info["SUVerifyUpdateBeforeExtraction"] is True
assert info["SURequireSignedFeed"] is True
assert info["SUSendProfileInfo"] is False

namespace = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
item = ET.parse(feed).getroot().find("./channel/item")
assert item is not None
assert item.findtext(namespace + "version") == version
enclosure = item.find("enclosure")
assert enclosure is not None
assert enclosure.get("url") == f"https://github.com/itswenb/fan-control/releases/download/v{version}/{archive.name}"
assert int(enclosure.attrib["length"]) == archive.stat().st_size
signature = enclosure.attrib[namespace + "edSignature"]


def verifies(path, signature=None, private_key=key_file):
    arguments = [tool_name, "--ed-key-file", str(private_key), "--verify", str(path)]
    if signature is not None:
        arguments.append(signature)
    result = subprocess.run(arguments, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    return result.returncode == 0


assert verifies(archive, signature), "安装包签名验证失败"
assert verifies(feed), "更新清单签名验证失败"
with tempfile.TemporaryDirectory(prefix="fan-release-verify-") as directory:
    root = pathlib.Path(directory)
    tampered_archive = root / "tampered.dmg"
    tampered_archive.write_bytes(archive.read_bytes() + b"tampered")
    assert not verifies(tampered_archive, signature), "被篡改的安装包被接受"
    tampered_feed = root / "tampered.xml"
    tampered_feed.write_bytes(feed.read_bytes().replace(b"<title>", b"<title>tampered ", 1))
    assert not verifies(tampered_feed), "被篡改的更新清单被接受"
    wrong_key = root / "wrong.key"
    wrong_key.write_text(base64.b64encode(bytes(32)).decode("ascii"))
    assert not verifies(archive, signature, wrong_key), "其他密钥能够验证发布安装包"
print("更新配置、版本、下载地址和签名通过；篡改安装包、篡改清单及错误密钥均被拒绝。")
