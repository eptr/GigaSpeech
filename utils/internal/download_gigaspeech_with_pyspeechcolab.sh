#!/usr/bin/env bash
# Copyright 2021  Jiayu Du
#                 Seasalt AI, Inc (Author: Guoguo Chen)
#                 Tsinghua University (Author: Shuzhou Chai)
#                 Xiaomi Corporation (Author: Junbo Zhang)

set -e
set -o pipefail

with_dict=false
host=tsinghua
subset={XL}
download_eval=true

. ./utils/parse_options.sh || exit 1

if [ $# -ne 2 ]; then
  echo "Usage: $0 <gigaspeech-download-dir> <gigaspeech-untar-dir>"
  echo " e.g.: $0 /disk1/audio_data/gigaspeech /disk2/gigaspeech"
  echo ""
  echo "This script downloads the entire GigaSpeech Dataset from Tsinghua host."
  echo "Archives (.tgz.aes/.tgz) are kept in <gigaspeech-download-dir>, and the"
  echo "extracted dataset goes to <gigaspeech-untar-dir>. The two dirs can be"
  echo "the same to get the old all-in-one layout."
  echo "We suggest having at least 1.0T of free space in the target directory."
  echo "If dataset resources are updated, you can re-run this script for "
  echo "incremental download."
  exit 1
fi

gigaspeech_dataset_dir=$1
untar_dir=$2
mkdir -p $gigaspeech_dataset_dir || exit 1;
mkdir -p $untar_dir || exit 1;

# Check dependency
python3 -c "import speechcolab" 2> /dev/null || \
  (echo "$0: This recipe needs the package speechcolab installed.";
   echo "To install:"
   echo "    pip install speechcolab"; exit 1)

# Check credential
if [ ! -f SAFEBOX/password ]; then
  echo "$0: Please apply for the download credentials (see the \"Download\""
  echo "$0: section in README) and it to SAFEBOX/password."
  exit 1
fi
PASSWORD=`cat SAFEBOX/password 2>/dev/null`
if [ -z "$PASSWORD" ]; then
  echo "$0: Error, SAFEBOX/password is empty."
  exit 1
fi

# false -> False, true -> True
with_dict=$(echo $with_dict | sed "s/\b\(.\)/\u\1/g")

# Download with PySpeechColab
python3 << END
import re
import tarfile
import zlib
from hashlib import pbkdf2_hmac
from pathlib import Path

from Crypto.Cipher import AES
from speechcolab.datasets.gigaspeech import GigaSpeech
from speechcolab.utils.download import download, file_md5


class GigaSpeechSplitUntar(GigaSpeech):
    # Archives are downloaded and decrypted into gigaspeech_dataset_dir,
    # extracted contents go to a separate untar_dir (wenet-style split).
    def __init__(self, download_dir, untar_dir):
        super().__init__(download_dir)
        self.untar_dir = Path(untar_dir)
        self.json_path = self.untar_dir / 'GigaSpeech.json'

    def download_and_process_object_from_release(self, remote_md5, obj):
        remote_obj = f'{self.gigaspeech_release_url}/{obj}'
        local_obj = self.gigaspeech_dataset_dir / obj
        need_download = True
        if local_obj.exists() and file_md5(local_obj) == remote_md5:
            print(f'Skipping {local_obj}, successfully retrieved already.')
            need_download = False

        retry_count = 3
        while need_download and retry_count > 0:
            local_obj.parent.mkdir(parents=True, exist_ok=True)
            print(f'Downloading from {re.sub(r"//.*@", "//", remote_obj)}')
            download(local_obj, remote_obj, show_progress_bar=True)
            if file_md5(local_obj) == remote_md5:
                print(f'Successfully verified md5 for {local_obj}')
                need_download = False
            else:
                print(f'MD5 mismatch for {local_obj}, retrying.')
                retry_count -= 1
        if need_download:
            raise ConnectionError(f'Can not retrieve the correct file {remote_obj} with md5 {remote_md5}')

        # Decrypt into the download dir, next to the archive.
        dec_obj = local_obj.with_suffix('')  # strip .aes
        with open(local_obj, 'rb') as f_in, open(dec_obj, 'wb') as f_out:
            bs = AES.block_size
            salt = f_in.read(bs)[len('Salted__'):]
            key_length = 32
            d = pbkdf2_hmac('sha256', self.password.encode(), salt, 10000, key_length + bs)
            key, iv = d[:key_length], d[key_length:key_length + bs]
            cipher = AES.new(key, AES.MODE_CBC, iv)
            while True:
                chunk = f_in.read(self.chunk_size)
                if not chunk:
                    break
                f_out.write(cipher.decrypt(chunk))

        # Extract into the untar dir, keeping the release directory layout.
        rel = dec_obj.relative_to(self.gigaspeech_dataset_dir).with_suffix('')
        if dec_obj.suffix == '.tgz':
            subdir = self.untar_dir / rel
            subdir.mkdir(parents=True, exist_ok=True)
            with tarfile.open(dec_obj) as tar:
                tar.extractall(path=subdir)
        elif dec_obj.suffix == '.gz':
            out_path = self.untar_dir / rel
            out_path.parent.mkdir(parents=True, exist_ok=True)
            z = zlib.decompressobj(zlib.MAX_WBITS | 16)
            with open(dec_obj, 'rb') as f_in, open(out_path, 'wb') as f_out:
                while True:
                    chunk = f_in.read(self.chunk_size)
                    if not chunk:
                        break
                    f_out.write(z.decompress(chunk))


gigaspeech = GigaSpeechSplitUntar('$gigaspeech_dataset_dir', '$untar_dir')
if '$download_eval' and '$subset' != '{DEV}' and '$subset' != '{TEST}':
    gigaspeech.download('$PASSWORD', subset='{DEV}', host='$host', with_dict=$with_dict)
    gigaspeech.download('$PASSWORD', subset='{TEST}', host='$host', with_dict=$with_dict)
gigaspeech.download('$PASSWORD', subset='$subset', host='$host', with_dict=$with_dict)
END


echo "$0: Done"
