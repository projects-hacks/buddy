"""How close each gap mark sits to what it is about, on every board a
faithfulness run saved, and which arrows lost their words for want of room.

- A correction (board.wrong) is about the element or arrow it rings; the
  number is the gap between the correction and the ring, which reaches 18
  board units past what it circles. 6 means touching.
- A missing part (board.missing with {near: id}) is about that element; the
  number is the gap between the two outlines.
- An arrow whose label has no frame was drawn without its words.

usage: python3 -I scripts/teach_back/mark_placement.py build/teach-back-runs/final
"""

import json
import pathlib
import re
import sys

RING_REACH = 18


def gap(first, second):
    horizontal = max(0, max(first["x"], second["x"]) - min(first["x"] + first["width"], second["x"] + second["width"]))
    vertical = max(0, max(first["y"], second["y"]) - min(first["y"] + first["height"], second["y"] + second["height"]))
    return max(horizontal, vertical)


def main():
    run = pathlib.Path(sys.argv[1])
    corrections, missing_parts, unlabelled, arrows = [], [], [], 0
    for board_path in sorted(run.glob("*/*board.json")):
        prefix = board_path.name[: -len("board.json")]
        board = json.loads(board_path.read_text())
        elements = {element["identifier"]: element for element in board["elements"]}
        name = f"{board_path.parent.name} {prefix or 'first'}".strip()
        for connector in board["connectors"]:
            arrows += 1
            if connector["label"] and not connector.get("labelFrame"):
                unlabelled.append(f'{name}: {connector["fromIdentifier"]}>{connector["toIdentifier"]} '
                                  f'({connector.get("ink") or "buddy"}) "{connector["label"]}"')
        for element in board["elements"]:
            target = element.get("correctsIdentifier")
            if not target:
                continue
            frame = elements[target]["frame"] if target in elements else next(
                (connector.get("labelFrame") for connector in board["connectors"]
                 if f'{connector["fromIdentifier"]}>{connector["toIdentifier"]}' == target), None)
            if frame:
                corrections.append((name, element["identifier"], gap(element["frame"], frame) - RING_REACH))
        program_path = board_path.parent / f"{prefix}check.program.js"
        if program_path.exists():
            for match in re.finditer(r'board\.missing\("([^"]+)",\s*"[^"]*"(?:,\s*\{near:\s*"([^"]+)"\})?', program_path.read_text()):
                identifier, near = match.group(1), match.group(2)
                placed = [key for key in elements if key == identifier or key.startswith(identifier + "-gap")]
                if placed and near in elements:
                    missing_parts.append((name, identifier, near, gap(elements[placed[-1]]["frame"], elements[near]["frame"])))

    print("corrections, gap to their ring (6 is touching):")
    for name, identifier, distance in corrections:
        print(f"  {name}: {identifier} {distance:.0f}")
    touching = sum(1 for *_, distance in corrections if distance <= 12)
    print(f"  {touching} of {len(corrections)} touch their ring")
    print("missing parts, gap to the element named in near:")
    for name, identifier, near, distance in missing_parts:
        print(f"  {name}: {identifier} beside {near}: {distance:.0f}")
    close = sum(1 for *_, distance in missing_parts if distance <= 70)
    print(f"  {close} of {len(missing_parts)} within 70 units (the board's own gap between parts is 46)")
    print(f"arrows drawn without their words: {len(unlabelled)} of {arrows}")
    for line in unlabelled:
        print(f"  {line}")


main()
