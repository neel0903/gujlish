"""
Assets for the iOS targets. Rebuilds gujlish.db from the committed TSVs
and copies it into ios/Assets/, where both the app and the keyboard
extension bundle it (without App Groups they cannot share one copy).

    python3 build_ios_assets.py
"""
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "ios", "Assets")


def main():
    subprocess.run([sys.executable, "build_db.py", "lexicon.tsv"], cwd=HERE, check=True)
    os.makedirs(ASSETS, exist_ok=True)
    shutil.copy2(os.path.join(HERE, "gujlish.db"), os.path.join(ASSETS, "gujlish.db"))
    size = os.path.getsize(os.path.join(ASSETS, "gujlish.db")) / 1e6
    print(f"ios/Assets/gujlish.db  {size:.1f} MB")

    # Lane 2 sentence fixer: the Core ML graphs and the words the model may
    # output (the gate's vocabulary), from lane2/ when it has been built.
    models = os.path.join(HERE, "lane2", "models")
    for name in ("GujlishEncoder.mlpackage", "GujlishDecoder.mlpackage"):
        src, dst = os.path.join(models, name), os.path.join(ASSETS, name)
        if os.path.isdir(src):
            if os.path.isdir(dst):
                shutil.rmtree(dst)
            shutil.copytree(src, dst)
            print(f"ios/Assets/{name}")
        else:
            print(f"(no {name}: run lane2/convert_coreml.py)")
    vocab = os.path.join(models, "gate_vocab.json")
    if os.path.exists(vocab):
        import json
        ok = json.load(open(vocab))["ok"]
        with open(os.path.join(ASSETS, "fix_vocab.txt"), "w") as f:
            f.write("\n".join(ok) + "\n")
        print(f"ios/Assets/fix_vocab.txt  {len(ok)} words")


if __name__ == "__main__":
    main()
