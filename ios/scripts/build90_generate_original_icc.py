#!/usr/bin/env python3
"""Generate source-exact binary ICC from pinned original io.py mapping.
No Apple/ColorSync approximation. Missing P3 linear fails closed.
"""
from pathlib import Path
import ast,hashlib,base64

ROOT=Path(__file__).resolve().parents[2]
SRC=ROOT/"src/spektrafilm/utils/io.py"
ICC=ROOT/"src/spektrafilm/data/icc"
OUT=ROOT/"ios/SpektraFilmPort/Build90GeneratedSourceICC.swift"
PIN="3c1a8787cac39bd5d3e6652c6e34a111a2565f3c"

def main():
    source=SRC.read_bytes()
    blob=hashlib.sha1(b"blob "+str(len(source)).encode()+b"\0"+source).hexdigest()
    assert blob==PIN,"Upstream io.py changed"
    tree=ast.parse(source)
    definitions=[
        node for node in tree.body
        if isinstance(node,ast.AnnAssign)
        and isinstance(node.target,ast.Name)
        and node.target.id=="_ICC_FILENAMES"
    ]
    assert len(definitions)==1
    mapping=ast.literal_eval(definitions[0].value)
    required=[
        ("sRGB",True),("sRGB",False),
        ("Display P3",True),
        ("ITU-R BT.2020",True),("ITU-R BT.2020",False),
    ]
    profiles=[]
    for key in required:
        assert key in mapping,key
        path=ICC/mapping[key]
        assert path.is_file(),("Original ICC missing",str(path))
        payload=path.read_bytes()
        assert len(payload)>=128 and payload[36:40]==b"acsp",path
        assert int.from_bytes(payload[0:4],"big")<=len(payload),(path,"ICC header")
        digest=hashlib.sha256(payload).hexdigest()
        profiles.append((key,payload,digest))
    rows=[
        "// Generated from Spektrafilm pinned ORIGINAL io.py ICC files.",
        "// The base64 is the byte-exact upstream ICC profile; never invent",
        "// a generic sRGB/P3/BT2020 profile or silently re-tag image pixels.",
        "import Foundation",
        "import CoreGraphics",
        "enum Build90GeneratedSourceICC {",
        "    static let sourceProfileData: [String:String] = [",
    ]
    for (name,encoded),payload,digest in profiles:
        key=name+"|"+("encoded" if encoded else "linear")
        data=base64.b64encode(payload).decode("ascii")
        escaped=key.replace('"','\\"')
        chunks=[data[i:i+768] for i in range(0,len(data),768)]
        rows.append(f'        "{escaped}": '+' +\n            '.join(
            f'"{part}"' for part in chunks
        )+",")
    rows += [
        "    ]",
        "    static let originalSHA256: [String:String] = ["
    ]
    for (name,encoded),payload,digest in profiles:
        key=name+"|"+("encoded" if encoded else "linear")
        rows.append(f'        "{key}":"{digest}",')
    rows += [
        "    ]",
        "    static func exactProfile(space:String,encoded:Bool)->Data? {",
        '        let key=space+(encoded ? "|encoded":"|linear")',
        "        guard let b64=sourceProfileData[key] else{return nil}",
        "        return Data(base64Encoded:b64)",
        "    }",
        "    static func exactCGColorSpace(space:String,encoded:Bool)->CGColorSpace? {",
        "        guard let data=exactProfile(space:space,encoded:encoded) else {",
        "            return nil",
        "        }",
        "        return CGColorSpace(iccData:data as CFData)",
        "    }",
        "}",
    ]
    OUT.write_text("\n".join(rows)+"\n",encoding="utf8")
    print("PASS original pinned source ICC byte-exact",
          len(profiles),"ICC profile pairs",
          sum(len(p[1]) for p in profiles),"bytes; SHA256 pinned")
if __name__=="__main__":
    main()
