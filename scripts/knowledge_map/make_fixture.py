"""Writes the fixture memories the map is rendered and timed on.

Three stores in the app's own concepts.json format, so LearningMemory can
load them as they are: 5 ideas (a first week), 40 (a term) and 300 (more
than a year of study). Ideas come in topics with the relations the filing
call would give them, plus ideas with no link yet. Dates, strengths and
ids are seeded, so every run writes the same files.

  python3 -I scripts/knowledge_map/make_fixture.py
"""

import datetime
import json
import pathlib
import random
import uuid

HERE = pathlib.Path(__file__).resolve().parent
NOW = datetime.datetime(2026, 11, 5, 12, 0, tzinfo=datetime.timezone.utc)

# Each topic: (hub, [(idea, kind, linked idea, example)]). The kind reads
# "idea <kind> linked idea", as ConceptRelation does.
TOPICS = [
    ("consistent hashing", [
        ("hash ring", "part of", "consistent hashing", "a clock face of servers"),
        ("virtual nodes", "part of", "consistent hashing", "each server on the ring many times"),
        ("modulo hashing", "alternative to", "consistent hashing", "key mod server count"),
        ("rebalancing", "uses", "hash ring", "adding a fourth cache box"),
    ]),
    ("event loop", [
        ("call stack", "part of", "event loop", "a stack of plates"),
        ("microtask queue", "part of", "event loop", "promises cutting the line"),
        ("promises", "uses", "microtask queue", "an order ticket at a cafe"),
        ("async await", "uses", "promises", "pausing a recipe while the oven heats"),
        ("debouncing", "uses", "event loop", "the search box firing on every key"),
        ("throttling", "contrasts with", "debouncing", "a turnstile letting one through a second"),
        ("callback hell", "contrasts with", "async await", "nested phone trees"),
    ]),
    ("binary search", [
        ("sorted arrays", "prerequisite of", "binary search", "a dictionary's alphabetical pages"),
        ("two pointers", "alternative to", "binary search", "walking in from both ends"),
        ("binary search tree", "uses", "binary search", "a guessing game tree"),
        ("lower bound", "part of", "binary search", "the first seat that fits"),
        ("big o notation", "prerequisite of", "binary search", "how the line at the bank grows"),
    ]),
    ("caching", [
        ("cache invalidation", "part of", "caching", "a stale menu board"),
        ("lru eviction", "part of", "caching", "the fridge's oldest leftovers"),
        ("write through cache", "alternative to", "write back cache", "writing in pen and pencil"),
        ("write back cache", "part of", "caching", "a notepad copied later"),
        ("cdn", "uses", "caching", "a corner shop stocking bestsellers"),
        ("cache stampede", "part of", "caching", "everyone refreshing at midnight"),
    ]),
    ("database indexes", [
        ("b tree", "part of", "database indexes", "a library's card catalogue"),
        ("composite index", "uses", "b tree", "sorting by surname then first name"),
        ("covering index", "part of", "database indexes", "an index card with the answer on it"),
        ("full table scan", "contrasts with", "database indexes", "reading every page of the book"),
        ("query planner", "uses", "database indexes", "a sat nav picking a route"),
    ]),
    ("transactions", [
        ("acid", "part of", "transactions", "a bank transfer"),
        ("isolation levels", "part of", "transactions", "how much of a draft others see"),
        ("two phase commit", "uses", "transactions", "two signatures on one contract"),
        ("deadlock", "part of", "transactions", "two cars at a narrow bridge"),
        ("optimistic locking", "alternative to", "pessimistic locking", "editing a wiki page"),
        ("pessimistic locking", "part of", "transactions", "a library book checked out"),
    ]),
    ("rate limiting", [
        ("token bucket", "part of", "rate limiting", "a jar refilled with coins"),
        ("leaky bucket", "alternative to", "token bucket", "a bucket dripping at a steady rate"),
        ("sliding window counter", "alternative to", "token bucket", "counting the last minute of visitors"),
        ("429 responses", "part of", "rate limiting", "a bouncer saying come back later"),
    ]),
    ("react rendering", [
        ("virtual dom", "part of", "react rendering", "a sketch before the painting"),
        ("reconciliation", "uses", "virtual dom", "spot the difference"),
        ("use effect", "part of", "react rendering", "a chore after cleaning up"),
        ("memoization", "uses", "react rendering", "a cheat sheet of past answers"),
        ("keys in lists", "part of", "reconciliation", "name tags at a party"),
        ("state lifting", "part of", "react rendering", "a shared family calendar"),
    ]),
    ("recursion", [
        ("base case", "part of", "recursion", "the last doll in a matryoshka"),
        ("stack overflow", "part of", "recursion", "mirrors facing mirrors"),
        ("dynamic programming", "uses", "recursion", "a staircase climbed once"),
        ("memo table", "part of", "dynamic programming", "a notebook of solved steps"),
        ("tail recursion", "part of", "recursion", "passing the baton forward"),
        ("backtracking", "uses", "recursion", "a maze with chalk marks"),
    ]),
    ("graph traversal", [
        ("breadth first search", "part of", "graph traversal", "ripples in a pond"),
        ("depth first search", "part of", "graph traversal", "exploring a cave to its end"),
        ("dijkstra's algorithm", "uses", "breadth first search", "the cheapest train route"),
        ("topological sort", "uses", "depth first search", "getting dressed in order"),
        ("adjacency list", "prerequisite of", "graph traversal", "a contacts list per person"),
        ("cycle detection", "uses", "depth first search", "a loop in a family tree"),
    ]),
    ("load balancing", [
        ("round robin", "part of", "load balancing", "dealing cards around a table"),
        ("health checks", "part of", "load balancing", "a nurse's ward round"),
        ("sticky sessions", "part of", "load balancing", "the same barista every morning"),
        ("least connections", "alternative to", "round robin", "the shortest supermarket queue"),
    ]),
    ("http", [
        ("status codes", "part of", "http", "traffic lights for requests"),
        ("cookies", "part of", "http", "a coat check ticket"),
        ("cors", "part of", "http", "a guest list at the door"),
        ("rest apis", "uses", "http", "a restaurant menu"),
        ("graphql", "alternative to", "rest apis", "a buffet instead of set courses"),
        ("websockets", "contrasts with", "http", "a phone call instead of letters"),
        ("idempotency keys", "part of", "rest apis", "retrying a payment without paying twice"),
    ]),
    ("hash maps", [
        ("hash functions", "part of", "hash maps", "a coat check numbering coats"),
        ("collisions", "part of", "hash maps", "two coats on one hook"),
        ("open addressing", "alternative to", "chaining", "taking the next free parking spot"),
        ("chaining", "part of", "hash maps", "a hook with several coats"),
        ("load factor", "part of", "hash maps", "how full the cloakroom is"),
    ]),
    ("message queues", [
        ("pub sub", "alternative to", "message queues", "a radio broadcast"),
        ("dead letter queue", "part of", "message queues", "the post office's undeliverable shelf"),
        ("at least once delivery", "part of", "message queues", "a courier who rings twice"),
        ("backpressure", "part of", "message queues", "a funnel overflowing"),
        ("kafka partitions", "uses", "message queues", "checkout lanes at a store"),
    ]),
    ("git", [
        ("commits", "part of", "git", "save points in a game"),
        ("branches", "part of", "git", "parallel drafts of an essay"),
        ("rebase", "alternative to", "merge commits", "rewriting a diary neatly"),
        ("merge commits", "part of", "git", "two rivers joining"),
        ("merge conflicts", "part of", "merge commits", "two people editing one sentence"),
    ]),
    ("neural networks", [
        ("gradient descent", "part of", "neural networks", "walking downhill in fog"),
        ("backpropagation", "uses", "gradient descent", "blame passed back down a chain"),
        ("activation functions", "part of", "neural networks", "a dimmer switch"),
        ("overfitting", "part of", "neural networks", "memorising the answers to last year's exam"),
        ("regularization", "contrasts with", "overfitting", "a speed limit on the model"),
        ("learning rate", "part of", "gradient descent", "the size of each step downhill"),
    ]),
    ("probability", [
        ("conditional probability", "part of", "probability", "rain given clouds"),
        ("bayes theorem", "uses", "conditional probability", "a doctor reading a test result"),
        ("expected value", "part of", "probability", "the average payout of a game"),
        ("independence", "part of", "probability", "two coin flips"),
    ]),
    ("operating systems", [
        ("processes", "part of", "operating systems", "separate kitchens"),
        ("threads", "part of", "processes", "cooks sharing one kitchen"),
        ("context switching", "part of", "operating systems", "a juggler swapping balls"),
        ("virtual memory", "part of", "operating systems", "a hotel's room numbers"),
        ("race conditions", "uses", "threads", "two people grabbing the last seat"),
        ("mutex", "contrasts with", "race conditions", "a single bathroom key"),
    ]),
    ("sorting", [
        ("quicksort", "part of", "sorting", "picking a pivot player"),
        ("merge sort", "alternative to", "quicksort", "merging two sorted hands of cards"),
        ("heap sort", "uses", "binary heap", "always taking the tallest"),
        ("binary heap", "part of", "sorting", "a tournament bracket"),
        ("stable sorting", "part of", "sorting", "keeping a queue's order for ties"),
    ]),
    ("authentication", [
        ("password hashing", "part of", "authentication", "a fingerprint, not a photo"),
        ("salting", "part of", "password hashing", "a pinch of salt per user"),
        ("jwt", "part of", "authentication", "a wristband at a festival"),
        ("oauth", "uses", "jwt", "a valet key for your car"),
        ("session tokens", "alternative to", "jwt", "a coat check stub"),
    ]),
    ("css layout", [
        ("flexbox", "part of", "css layout", "books on a shelf"),
        ("css grid", "alternative to", "flexbox", "a spreadsheet of boxes"),
        ("box model", "prerequisite of", "css layout", "a framed picture with a mat"),
        ("specificity", "part of", "css layout", "who wins an argument"),
    ]),
    ("replication", [
        ("leader follower replication", "part of", "replication", "a teacher and note takers"),
        ("eventual consistency", "part of", "replication", "a rumour reaching everyone"),
        ("quorum reads", "uses", "replication", "a jury majority"),
        ("read replicas", "part of", "replication", "photocopies in each classroom"),
        ("split brain", "part of", "replication", "two captains on one ship"),
    ]),
    ("sharding", [
        ("shard keys", "part of", "sharding", "filing cabinets by surname"),
        ("hot partitions", "part of", "sharding", "the busiest till at lunch"),
        ("resharding", "uses", "consistent hashing", "moving house with labelled boxes"),
    ]),
    ("tries", [
        ("prefix search", "uses", "tries", "typing the start of a contact's name"),
        ("autocomplete", "uses", "prefix search", "a phone keyboard's guesses"),
        ("radix tree", "alternative to", "tries", "a trie with shortcuts"),
    ]),
    ("concurrency patterns", [
        ("producer consumer", "part of", "concurrency patterns", "a bakery and its shop"),
        ("thread pools", "part of", "concurrency patterns", "a taxi rank"),
        ("futures", "part of", "concurrency patterns", "a receipt for a coat being repaired"),
        ("actor model", "alternative to", "thread pools", "pen pals who never share a desk"),
    ]),
    ("linear algebra", [
        ("vectors", "part of", "linear algebra", "an arrow on a map"),
        ("matrix multiplication", "part of", "linear algebra", "a recipe scaled for a crowd"),
        ("dot product", "part of", "vectors", "how much two arrows agree"),
        ("eigenvectors", "uses", "matrix multiplication", "a spinning top's axis"),
    ]),
    ("compilers", [
        ("tokenizer", "part of", "compilers", "cutting a sentence into words"),
        ("abstract syntax tree", "part of", "compilers", "a sentence diagram"),
        ("type checking", "uses", "abstract syntax tree", "a spell checker for meaning"),
        ("garbage collection", "contrasts with", "manual memory management", "a cleaner after the party"),
        ("manual memory management", "part of", "compilers", "washing your own dishes"),
    ]),
    ("testing", [
        ("unit tests", "part of", "testing", "checking each brick"),
        ("integration tests", "part of", "testing", "checking the wall stands"),
        ("mocking", "uses", "unit tests", "a stunt double"),
        ("property based testing", "alternative to", "unit tests", "a fuzzing inspector"),
    ]),
]

LOOSE = [
    ("regular expressions", "a bouncer with a pattern list"),
    ("bit manipulation", "light switches in a row"),
    ("unicode", "a world atlas of letters"),
    ("floating point error", "measuring with a stretchy ruler"),
    ("dns", "a phone book for websites"),
    ("docker containers", "shipping containers for code"),
    ("feature flags", "a dimmer for a new feature"),
    ("bloom filters", "a guest list that can only say maybe"),
    ("time zones", "clocks on a hotel wall"),
    ("cron jobs", "an alarm clock for scripts"),
    ("utf 8 encoding", "variable sized parcels"),
    ("tcp handshake", "a three step phone greeting"),
    ("udp", "postcards without tracking"),
    ("big endian", "writing the date year first"),
    ("monads", "a lunchbox with rules"),
    ("closures", "a backpack a function carries"),
    ("currying", "ordering a meal one choice at a time"),
    ("dependency injection", "handing a chef their knives"),
    ("singleton pattern", "the one office printer"),
    ("observer pattern", "a newsletter subscription"),
    ("immutability", "writing in pen"),
    ("pagination", "chapters in a long book"),
    ("cursor pagination", "a bookmark instead of page numbers"),
    ("webhooks", "a doorbell instead of checking the door"),
    ("exponential backoff", "waiting longer each time a friend is busy"),
    ("circuit breakers", "a fuse box for services"),
    ("service discovery", "a reception desk directory"),
    ("blue green deploys", "two stages, one lit"),
    ("canary releases", "a taste tester"),
    ("observability", "a car's dashboard"),
    ("structured logging", "a form instead of a diary"),
    ("percentiles", "the slowest in a race of a hundred"),
    ("a b testing", "two shop window displays"),
    ("p values", "how surprised to be"),
    ("standard deviation", "how spread out a class's heights are"),
    ("big data joins", "matching two guest lists"),
    ("map reduce", "counting votes by district"),
    ("stream processing", "a conveyor belt"),
    ("event sourcing", "a bank statement instead of a balance"),
    ("cqrs", "a separate counter for orders and pickups"),
    ("geohashing", "postcodes for the planet"),
    ("quadtrees", "zooming into a map's squares"),
    ("skip lists", "express stops on a train line"),
    ("union find", "merging friend groups"),
    ("segment trees", "a tournament of range sums"),
    ("fenwick trees", "a clever running total"),
    ("sliding window", "a train window passing a view"),
    ("prefix sums", "mile markers on a road"),
    ("monotonic stack", "people in a queue looking over heads"),
    ("kadane's algorithm", "deciding to drop a losing streak"),
    ("greedy algorithms", "taking the biggest coin first"),
    ("np completeness", "a puzzle checked fast but solved slowly"),
    ("halting problem", "a program predicting itself"),
    ("lambda calculus", "maths of only functions"),
    ("finite state machines", "a vending machine"),
    ("raft consensus", "a class electing a monitor"),
    ("vector clocks", "everyone's own diary dates"),
    ("crdts", "a shopping list two phones edit"),
    ("merkle trees", "a checksum of checksums"),
    ("public key cryptography", "a padlock anyone can close"),
    ("tls", "a sealed envelope with a signature"),
    ("xss", "graffiti that runs"),
    ("sql injection", "a form that rewrites the question"),
    ("csrf", "a forged permission slip"),
]


def concept_record(rng, name, angle, index, total):
    concept_id = uuid.UUID(int=rng.getrandbits(128), version=4)
    # Older ideas first, spread over the last 400 days.
    first_days_ago = 400 * (1 - index / max(1, total)) + rng.uniform(0, 6)
    times = rng.choices([1, 2, 3, 4, 6], weights=[45, 25, 15, 10, 5])[0]
    last_days_ago = rng.uniform(0, min(first_days_ago, 90))
    strength_band = rng.random()
    # Mostly remembered, a good share fading, some fading out.
    if strength_band < 0.5:
        stability = last_days_ago * rng.uniform(4, 12) + 3
    elif strength_band < 0.8:
        stability = max(1.0, last_days_ago * rng.uniform(0.5, 1.4))
    else:
        stability = max(1.0, last_days_ago * rng.uniform(0.06, 0.25))
    lost = 1 if rng.random() < 0.1 else 0
    first = NOW - datetime.timedelta(days=first_days_ago)
    last = NOW - datetime.timedelta(days=last_days_ago)
    return {
        "id": str(concept_id).upper(),
        "name": name,
        "aliases": [],
        "cues": [],
        "summary": f"{name[0].upper() + name[1:]}, explained with {angle}.",
        "lastAngle": angle,
        "firstExplainedAt": first.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "lastExplainedAt": last.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "timesExplained": times,
        "timesLost": lost,
        "stabilityDays": round(stability, 2),
        "lessonTitles": [],
        "relations": [],
    }


def build(topic_count, loose_count, seed):
    rng = random.Random(seed)
    ideas = []  # (name, angle, links as (kind, target name))
    for hub, members in TOPICS[:topic_count]:
        ideas.append((hub, members[0][3] if members else "an everyday example", []))
        for name, kind, target, angle in members:
            ideas.append((name, angle, [(kind, target)]))
    for name, angle in LOOSE[:loose_count]:
        ideas.append((name, angle, []))
    names = {name for name, _, _ in ideas}
    order = list(range(len(ideas)))
    rng.shuffle(order)
    records = {}
    for position, idea_index in enumerate(order):
        name, angle, _ = ideas[idea_index]
        records[name] = concept_record(rng, name, angle, position, len(ideas))
    for name, _, links in ideas:
        for kind, target in links:
            if target in names:
                records[name]["relations"].append({"kind": kind, "targetID": records[target]["id"]})
    return list(records.values())


def write(name, concepts):
    path = HERE / name
    path.write_text(json.dumps({"version": 1, "embeddingModel": None, "concepts": concepts}, indent=1) + "\n")
    links = sum(len(concept["relations"]) for concept in concepts)
    print(f"wrote {path.name}: {len(concepts)} ideas, {links} relations")


write("fixture_5.json", build(topic_count=1, loose_count=0, seed=5))
write("fixture_40.json", build(topic_count=5, loose_count=8, seed=40))
everything = build(topic_count=len(TOPICS), loose_count=len(LOOSE), seed=300)
# Fill to exactly 300 with follow-up ideas on the same topics, the way a
# student comes back to a topic for its edge cases and trade-offs.
extra = 300 - len(everything)
rng = random.Random(3000)
follow_ups = ["edge cases", "tradeoffs", "at scale"]
for number in range(max(0, extra)):
    hub = TOPICS[number % len(TOPICS)][0]
    follow_up = follow_ups[(number // len(TOPICS)) % len(follow_ups)]
    record = concept_record(rng, f"{hub} {follow_up}", f"a worked {hub} problem", number, max(1, extra))
    hub_record = next(concept for concept in everything if concept["name"] == hub)
    record["relations"].append({"kind": "part of", "targetID": hub_record["id"]})
    everything.append(record)
write("fixture_300.json", everything[:300])
