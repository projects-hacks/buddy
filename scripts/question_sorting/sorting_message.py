"""What the app sends Haiku to sort a message (QuestionKindClassifier.sortingMessage),
for the graders. The test sets record only whether an answer came before, not
what it was, so every follow-up is graded after the same plain exchange."""

PREVIOUS = ("<previous_exchange>\n<student_asked>what does this function do</student_asked>\n"
            "<buddy_said>it walks the list once and keeps the largest value it has seen so far, "
            "then returns it at the end.</buddy_said>\n</previous_exchange>")
FIRST = "<previous_exchange>none: this is the first thing they have said</previous_exchange>"


def sorting_message(question: str, after_answer: bool) -> str:
    return f"{PREVIOUS if after_answer else FIRST}\n<message>{question}</message>"
