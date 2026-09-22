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


if __name__ == "__main__":
    main()
