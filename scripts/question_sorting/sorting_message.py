"""What the app sends Haiku to sort a message (QuestionKindClassifier.sortingMessage),
for the graders. The test sets record only whether an answer came before, not
what it was, so every follow-up is graded after the same plain exchange."""

PREVIOUS = ("<previous_exchange>\n<student_asked>what does this function do</student_asked>\n"
            "<buddy_said>it walks the list once and keeps the largest value it has seen so far, "
            "then returns it at the end.</buddy_said>\n</previous_exchange>")
FIRST = "<previous_exchange>none: this is the first thing they have said</previous_exchange>"


PLAYING = "\n<app_in_front>a video or other sound was playing in it in the last few minutes, so he or she is probably someone in the video, and missing what they said is a question about the video, not a failed answer from Buddy</app_in_front>"


def sorting_message(question: str, after_answer: bool, video_playing: bool = False) -> str:
    return f"{PREVIOUS if after_answer else FIRST}{PLAYING if video_playing else ''}\n<message>{question}</message>"
