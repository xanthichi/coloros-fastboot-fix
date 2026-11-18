import argparse
import bz2
import hashlib
import lzma
import struct
import sys
from pathlib import Path
from zipfile import BadZipFile, ZipFile


PARTITIONS = ("engineering_cdt", "abl")
LIMIT = 64 * 1024 * 1024


def read_exact(stream, size):
    data = stream.read(size)
    if len(data) != size:
        raise ValueError("Truncated payload")
    return data


def varint(data, cursor):
    value = 0
    for shift in range(0, 70, 7):
        if cursor >= len(data) or (shift == 63 and data[cursor] > 1):
            break
        byte = data[cursor]
        cursor += 1
        value |= (byte & 127) << shift
        if byte < 128:
            return value, cursor
    raise ValueError("Invalid manifest varint")


def fields(data):
    result = {}
    cursor = 0
    while cursor < len(data):
        tag, cursor = varint(data, cursor)
        number, wire = divmod(tag, 8)
        if not 0 < number < 1 << 29:
            raise ValueError("Invalid manifest field number")
        if wire == 0:
            value, cursor = varint(data, cursor)
        elif wire in (1, 2, 5):
            if wire == 2:
                size, cursor = varint(data, cursor)
            else:
                size = 8 if wire == 1 else 4
            end = cursor + size
            if end > len(data):
                raise ValueError("Truncated manifest field")
            value, cursor = data[cursor:end], end
        else:
            raise ValueError("Unsupported manifest wire type")
        result.setdefault(number, []).append(value)
    return result


def field(message, number, kind, default=None):
    values = message.get(number, [])
    if not values and default is not None:
        return default
    if len(values) != 1 or not isinstance(values[0], kind):
        raise ValueError(f"Invalid or missing manifest field {number}")
    return values[0]


def manifest_from(payload, payload_size):
    magic, version, size, signature_size = struct.unpack(">4sQQI", read_exact(payload, 24))
    data_start = 24 + size + signature_size
    if magic != b"CrAU" or version != 2 or not 0 < size <= LIMIT or data_start > payload_size:
        raise ValueError("Expected a supported Android OTA v2 payload")
    manifest = fields(read_exact(payload, size))
    block_size = field(manifest, 3, int, 4096)
    if not 0 < block_size <= LIMIT or block_size & (block_size - 1):
        raise ValueError("Invalid block size")
    data_size = field(manifest, 4, int, payload_size - data_start)
    if data_size > payload_size - data_start:
        raise ValueError("Invalid payload data size")
    partitions = {}
    for entry in manifest.get(13, []):
        partition = fields(entry)
        name = field(partition, 1, bytes).decode("utf-8")
        if name in partitions:
            raise ValueError(f"Duplicate partition: {name}")
        partitions[name] = partition
    return data_start, data_size, block_size, partitions


def decode_operation(payload, data_start, data_size, operation, output_size):
    kind = field(operation, 1, int)
    offset = field(operation, 2, int, 0)
    length = field(operation, 3, int, 0)
    if operation.get(4) or kind not in (0, 1, 6, 8):
        raise ValueError(f"Unsupported or source-dependent operation: {kind}")
    if kind == 6:
        if length:
            raise ValueError("Unexpected data for ZERO operation")
        return bytes(output_size)
    if not 0 < length <= LIMIT or offset + length > data_size:
        raise ValueError("Operation extends outside payload data")
    payload.seek(data_start + offset)
    data = read_exact(payload, length)
    expected = field(operation, 8, bytes, b"")
    if expected and hashlib.sha256(data).digest() != expected:
        raise ValueError("Operation data SHA-256 mismatch")
    if kind in (1, 8):
        decoder = (bz2.BZ2Decompressor() if kind == 1 else
                   lzma.LZMADecompressor(format=lzma.FORMAT_XZ, memlimit=LIMIT))
        data = decoder.decompress(data, max_length=output_size + 1)
        if not decoder.eof or decoder.unused_data:
            raise ValueError("Invalid compressed operation data")
    if len(data) != output_size:
        raise ValueError("Operation data length does not match its extents")
    return data


def build_image(payload, data_start, data_size, block_size, partition):
    info = fields(field(partition, 7, bytes))
    size = field(info, 1, int)
    expected = field(info, 2, bytes)
    if partition.get(6) or not 0 < size <= LIMIT or len(expected) != 32:
        raise ValueError("Expected a full partition image with SHA-256 (up to 64 MiB)")
    image = bytearray(size)
    ranges = []
    for entry in partition.get(8, []):
        operation = fields(entry)
        extents = []
        output_size = 0
        for encoded in operation.get(6, []):
            extent = fields(encoded)
            start = field(extent, 1, int) * block_size
            length = field(extent, 2, int) * block_size
            if not length or start + length > size or output_size + length > size:
                raise ValueError("Invalid destination extent")
            extents.append((start, length))
            output_size += length
        if not output_size or field(operation, 7, int, output_size) != output_size:
            raise ValueError("Invalid operation output size")
        data = decode_operation(payload, data_start, data_size, operation, output_size)
        cursor = 0
        for start, length in extents:
            image[start:start + length] = data[cursor:cursor + length]
            ranges.append((start, start + length))
            cursor += length
    end = 0
    for start, next_end in sorted(ranges):
        if start != end:
            raise ValueError("Missing or overlapping destination extents")
        end = next_end
    if end != size or hashlib.sha256(image).digest() != expected:
        raise ValueError("Incomplete image or partition SHA-256 mismatch")
    return image, expected.hex()


def extract(archive_path, output_dir=None, list_only=False):
    with ZipFile(archive_path) as archive:
        entries = [entry for entry in archive.infolist() if entry.filename == "payload.bin"]
        if len(entries) != 1:
            raise ValueError("Expected one payload.bin at the root of the OTA ZIP")
        with archive.open(entries[0]) as payload:
            data_start, data_size, block_size, partitions = manifest_from(payload, entries[0].file_size)
            if list_only:
                return {name: name in partitions for name in PARTITIONS}
            missing = [name for name in PARTITIONS if name not in partitions]
            if missing:
                raise ValueError("Missing partitions: " + ", ".join(missing))
            images = {
                name: build_image(payload, data_start, data_size, block_size, partition)
                for name, partition in partitions.items() if name in PARTITIONS
            }

    output_dir = output_dir or archive_path.parent / f"{archive_path.stem}_images"
    output_dir.mkdir()
    written = []
    try:
        for name, (image, _) in images.items():
            path = output_dir / f"{name}.img"
            with path.open("xb") as stream:
                written.append(path)
                stream.write(image)
    except BaseException:
        for path in written:
            path.unlink()
        output_dir.rmdir()
        raise
    return {output_dir / f"{name}.img": (len(image), digest)
            for name, (image, digest) in images.items()}


def main():
    parser = argparse.ArgumentParser(description="Extract engineering_cdt and abl from an Android OTA ZIP.")
    parser.add_argument("zip", nargs="?", help="Absolute path to the OTA ZIP")
    parser.add_argument("--output", type=Path, help="New directory for the two verified images")
    parser.add_argument("--list", action="store_true", help="Check manifest membership only")
    args = parser.parse_args()
    try:
        entered = args.zip or input("Absolute path to OTA ZIP: ")
        path = Path(entered.strip().strip(chr(34)).strip(chr(39)))
        if not path.is_absolute():
            raise ValueError("Enter an absolute ZIP path")
        results = extract(path, args.output, args.list)
        if args.list:
            for name, present in results.items():
                print(f"{name}: {'present' if present else 'absent'}")
        else:
            for image_path, (size, digest) in results.items():
                print(f"{image_path} ({size:,} bytes)\nSHA-256 {digest}")
    except (OSError, ValueError, TypeError, EOFError, BadZipFile, lzma.LZMAError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
