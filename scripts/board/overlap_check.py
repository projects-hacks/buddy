"""Checks every board a harness run saved for words drawn on top of things.

For each turnN.board.json (a lesson) or board.json and again-board.json
(teach it back) under the run directory, every arrow label and
every stub tag is tested against every element (a group only by its title
band, and by its border, which a label must not straddle), every other
label and every other tag. Element frames are tested against each other,
except a group against its own members, and every arrow's path against
every element other than its ends and every other arrow's label. Any
overlap is printed; the last line is the total, which should be zero.

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
    # Arrows through words: an arrow's pen path, curves sampled as the
    # engine draws them, crossing an element other than its own ends, or
    # another arrow's label. On a lesson board an arrow may pass behind one
    # filled shape (a box, circle, note, list or table hides it), never
    # across a label's bare words; on a teach-back board (any element with
    # an ink) it may cross nothing.
    is_teach_back = any(element.get("ink") for element in elements)
    for connector in board["connectors"]:
        name = f'{connector["fromIdentifier"]}>{connector["toIdentifier"]}'
        ends = {connector["fromIdentifier"], connector["toIdentifier"]}
        points = path_points(connector.get("routePoints") or []) + path_points(connector.get("targetStubPoints") or [])
        for element in solid:
            if element["identifier"] in ends:
                continue
            if not is_teach_back and element["kind"] != "label":
                continue
            if any(inside(point, rect(element["frame"]), margin=3) for point in points):
                problems.append(f'arrow {name} through {element["identifier"]}')
        for other in board["connectors"]:
            if other is connector or not other.get("labelFrame"):
                continue
            if any(inside(point, rect(other["labelFrame"]), margin=2) for point in points):
                problems.append(f'arrow {name} through the label of {other["fromIdentifier"]}>{other["toIdentifier"]}')
    return problems


def path_points(route):
    """Points every few units along the pen path. Three points are a bowed
    curve through its middle point, as BoardLayout.sampledPoints has it."""
    coordinates = [(point["x"], point["y"]) for point in route]
    if len(coordinates) == 3:
        (start_x, start_y), (through_x, through_y), (end_x, end_y) = coordinates
        control = (2 * through_x - (start_x + end_x) / 2, 2 * through_y - (start_y + end_y) / 2)
        coordinates = []
        for step in range(49):
            fraction = step / 48
            inverse = 1 - fraction
            coordinates.append((inverse * inverse * start_x + 2 * inverse * fraction * control[0] + fraction * fraction * end_x,
                                inverse * inverse * start_y + 2 * inverse * fraction * control[1] + fraction * fraction * end_y))
        return coordinates
    sampled = []
    for (first_x, first_y), (second_x, second_y) in zip(coordinates, coordinates[1:]):
        steps = max(1, int(max(abs(second_x - first_x), abs(second_y - first_y)) / 4))
        for step in range(steps + 1):
            fraction = step / steps
            sampled.append((first_x + (second_x - first_x) * fraction, first_y + (second_y - first_y) * fraction))
    return sampled


def inside(point, frame, margin=0.0):
    return frame[0] + margin < point[0] < frame[2] - margin and frame[1] + margin < point[1] < frame[3] - margin


def main():
    run = pathlib.Path(sys.argv[1])
    total = 0
    # Lesson boards are turnN.board.json; teach-back's are board.json and
    # again-board.json.
    boards = sorted(run.glob("*/*board.json"))
    for path in boards:
        problems = check(json.loads(path.read_text()))
        total += len(problems)
        for problem in problems:
            print(f"{path.parent.name} {path.stem.split('.')[0]}: {problem}")
    print(f"{total} overlaps in {len(boards)} boards")


main()
