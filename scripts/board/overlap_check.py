"""Checks every board a harness run saved for words drawn on top of things.

For each turnN.board.json under the run directory, every arrow label and
every stub tag is tested against every element (a group only by its title
band, and by its border, which a label must not straddle), every other
label and every other tag. Element frames are tested against each other,
except a group against its own members. Any overlap is printed; the last
line is the total, which should be zero.

usage: python3 -I overlap_check.py <run_dir>
"""

import json
import pathlib
import sys


def rect(frame):
    return (frame["x"], frame["y"], frame["x"] + frame["width"], frame["y"] + frame["height"])


def overlaps(first, second, margin=0.0):
    return (first[0] < second[2] - margin and first[2] > second[0] + margin
            and first[1] < second[3] - margin and first[3] > second[1] + margin)


def contains(outer, inner):
    return outer[0] <= inner[0] and outer[1] <= inner[1] and outer[2] >= inner[2] and outer[3] >= inner[3]


def check(board):
    problems = []
    elements = board["elements"]
    groups = [element for element in elements if element["kind"] == "group"]
    solid = [element for element in elements if element["kind"] != "group"]
    title_bands = {group["identifier"]: (rect(group["frame"])[0], rect(group["frame"])[1],
                                         rect(group["frame"])[2], rect(group["frame"])[1] + 44) for group in groups}
    words = []
    for connector in board["connectors"]:
        name = f'{connector["fromIdentifier"]}>{connector["toIdentifier"]}'
        ends = {connector["fromIdentifier"], connector["toIdentifier"]}
        if connector.get("labelFrame"):
            words.append((f"label of {name}", rect(connector["labelFrame"]), set()))
        for index, tag in enumerate(connector.get("stubTagFrames") or []):
            # A tag may sit as a badge on the corner of its own end.
            words.append((f"tag {index + 1} of {name}", rect(tag), ends))

    for label, frame, own_ends in words:
        for element in solid:
            if element["identifier"] in own_ends:
                continue
            if overlaps(frame, rect(element["frame"]), margin=1):
                problems.append(f'{label} on {element["identifier"]}')
        for group in groups:
            if overlaps(frame, title_bands[group["identifier"]], margin=1):
                problems.append(f'{label} on the title of {group["identifier"]}')
            outer = rect(group["frame"])
            if overlaps(frame, outer, margin=1) and not contains(outer, frame):
                problems.append(f'{label} across the border of {group["identifier"]}')
    for index, (label, frame, _) in enumerate(words):
        for other_label, other_frame, _ in words[index + 1:]:
            if overlaps(frame, other_frame, margin=1):
                problems.append(f"{label} on {other_label}")
    for index, element in enumerate(solid):
        for other in solid[index + 1:]:
            if overlaps(rect(element["frame"]), rect(other["frame"]), margin=1):
                problems.append(f'{element["identifier"]} on {other["identifier"]}')
    return problems


def main():
    run = pathlib.Path(sys.argv[1])
    total = 0
    for path in sorted(run.glob("*/turn*.board.json")):
        problems = check(json.loads(path.read_text()))
        total += len(problems)
        for problem in problems:
            print(f"{path.parent.name} {path.stem.split('.')[0]}: {problem}")
    print(f"{total} overlaps in {len(list(run.glob('*/turn*.board.json')))} boards")


main()
