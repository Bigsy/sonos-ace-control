#!/usr/bin/env python3
"""Summarise Bluetooth ATT traffic, redacting authentication token values.

Accepts an Android bugreport ZIP or an extracted btsnoop file. Inspection material
stays in private/. Reports never print SMP keys or common/primary access tokens.
"""
import argparse
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path
import struct
import uuid
import zipfile


def tlvs(data):
    out = {}
    offset = 2
    while offset < len(data):
        if offset + 3 > len(data):
            return None
        tag, count = data[offset], int.from_bytes(data[offset + 1:offset + 3], 'big')
        offset += 3
        if offset + count > len(data) or tag in out:
            return None
        out[tag] = data[offset:offset + count]
        offset += count
    return out


def describe(data):
    if not data:
        return None
    if data[0] == 1 and len(data) >= 5 and data[1] <= 7:
        fields = tlvs(data)
        if fields is not None:
            safe = {str(k): ('<redacted token>' if k == 4 else v.hex(' ')) for k, v in fields.items()}
            return f'AAP message={data[1]} elements={safe}'
    if data[0] == 0 and len(data) >= 5:
        fields = tlvs(data)
        if fields is not None:
            # Attestation may contain identity/certificate material. Only report sizes.
            return f'ASP message={data[1]} element_lengths={ {k: len(v) for k,v in fields.items()} }'
    if len(data) >= 3 and data[0] in (0, 1, 2) and data[1] <= 8:
        if data[1] == 2:
            return f'ACP settings pdu={data[0]} command={data[2]} bytes={data.hex(" ")}'
        return f'ACP namespace={data[1]} pdu={data[0]} command={data[2]} length={len(data)}'
    return None


def inspect(path):
    with path.open('rb') as stream:
        header = stream.read(16)
        if len(header) != 16 or header[:8] != b'btsnoop\0':
            raise ValueError(f'{path.name}: not a btsnoop file')
        version, datalink = struct.unpack('>II', header[8:])
        print(f'Capture {path.name}: version={version}, datalink={datalink}')
        if datalink != 1002:
            raise ValueError('Only HCI UART (1002) captures are supported')
        fragments = {}
        stats = Counter()
        while raw := stream.read(24):
            if len(raw) != 24:
                raise ValueError('Truncated record header')
            original, included, flags, drops, stamp = struct.unpack('>IIIIQ', raw)
            packet = stream.read(included)
            if len(packet) != included:
                raise ValueError('Truncated record payload')
            stats['records'] += 1
            if not packet or packet[0] != 2 or len(packet) < 5:
                continue
            handle_flags, count = struct.unpack('<HH', packet[1:5])
            handle, boundary = handle_flags & 0xfff, (handle_flags >> 12) & 3
            key = (handle, flags & 1)
            payload = packet[5:5 + count]
            if boundary == 1:
                if key not in fragments:
                    stats['orphan_fragments'] += 1
                    continue
                fragments[key] += payload
            else:
                fragments[key] = payload
            buf = fragments[key]
            if len(buf) < 4:
                continue
            length, cid = struct.unpack('<HH', buf[:4])
            if len(buf) < length + 4:
                continue
            del fragments[key]
            if cid != 4:
                continue
            att = buf[4:4 + length]
            stats['att_packets'] += 1
            if not att:
                continue
            timestamp = (datetime(1970, 1, 1, tzinfo=timezone.utc) + timedelta(microseconds=stamp - 0x00dcddb30f2f8000)).isoformat(timespec='milliseconds')
            direction = 'RX' if flags & 1 else 'TX'
            prefix = f'{timestamp} conn={handle:03x} {direction}'
            if att[0] in (0x12, 0x52, 0x1b, 0x1d) and len(att) >= 3:
                attribute = int.from_bytes(att[1:3], 'little')
                summary = describe(att[3:])
                if summary:
                    print(f'{prefix} attr={attribute:04x} {summary}')
            elif att[0] == 0x09 and len(att) >= 2 and att[1] == 21:
                for offset in range(2, len(att), 21):
                    item = att[offset:offset + 21]
                    if len(item) != 21:
                        continue
                    service_uuid = str(uuid.UUID(bytes=bytes(reversed(item[5:21]))))
                    if service_uuid.startswith('c44f42b1'):
                        print(f'{prefix} Sonos characteristic attr={int.from_bytes(item[3:5], "little"):04x} uuid={service_uuid} properties={item[2]}')
        print('Summary:', dict(stats))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path)
    parser.add_argument('--output-dir', type=Path, default=Path('private/captures'))
    args = parser.parse_args()
    if zipfile.is_zipfile(args.capture):
        args.output_dir.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(args.capture) as archive:
            names = [n for n in archive.namelist() if 'btsnoop' in n.lower() or 'btsnooz' in n.lower()]
            print('Bluetooth capture entries:', names)
            for index, name in enumerate(names):
                payload = archive.read(name)
                if payload.startswith(b'btsnoop\0'):
                    target = args.output_dir / f'{index}-{Path(name).name}'
                    target.write_bytes(payload)
                    inspect(target)
            if not names:
                print('No standalone Bluetooth capture in this report.')
    else:
        inspect(args.capture)


if __name__ == '__main__':
    main()
