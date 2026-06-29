<!-- Ch 1.2 — CODE ✓ NATIVE-GATED (2026-06-27); prose pending voice review. Snippet prints
     the count via Output.print (main visits Output). Native run via toolchain/yonc:
     stdout "1", exit 0 — two identical genomes dedup to one. BONUS observed in the build:
     the structural-value-numbering pass collapsed 1 structurally-equivalent op (content-
     addressing at COMPILE time; candidate chapter closer — verify the pass before using).
     Project: regression/book/jp/01_2_counted/. Style: no em-dashes; reserved words stay
     keywords (holds/world/becomes); name casts; reader-facing. -->

# Chapter 1.2 · Counted by Computer

## The scene

On the tour, someone finally asks the question the brochure was written to avoid, and
Wu has the answer ready. The animals are counted by computer every few minutes. If one
were ever missing, the system would know at once. The population is two hundred and
thirty-eight, and the number on the screen has read two hundred and thirty-eight all
day. The count is the proof that the park is under control.

Hold onto how reasonable that sounds, because nothing in it is false, and it is the
beginning of everything that goes wrong. To count is to decide what makes two things
two. The computer counts individuals. But what is an individual, when every animal in
the park was grown from a sequence, the sequence can be written down, and two animals
can be written from the same sequence? The question sounds like philosophy. In Yon it is
a line of code with an answer.

## The idea

**On the philosophical plane.** Leibniz had a principle: two things that share every
property are not two things, they are one. The identity of indiscernibles. If you cannot
point to a single difference, there is no difference to point to. The trouble starts
when you ask what counts as a property. Is "the animal in the eastern paddock" a fact
about the animal, or about where it happens to stand? Crichton's park runs on never
asking. Yon makes you answer.

**In the language.** Yon identifies a value by its content, and by nothing else. There is
no hidden name and no fresh reference handed out at birth that would make two identical
things count as two. This is content-addressing: the address of a value *is* its content.
Put the same thing into a content-addressed collection twice and it is there once,
because the second one was never a second one.

**On the silicon.** A value's content is run through a fast hash (FNV-1a), and when two
hashes collide the bytes are compared directly, so the answer is exact and not a
probability. Equal content lands in the same slot of the heap. Two identical genomes are
not stored twice and cleaned up later; they were one slot from the start.

## The code

A herd, kept as a content-addressed set. We add the same genome twice and ask how many
the set contains.

```yon
// Entry.yon, a herd as a content-addressed set
place Entry { }

fun main(): number visits Output {
  be herd0 holds HashSet.empty()
  be herd1 holds HashSet.add(herd0, 100247)
  be herd2 holds HashSet.add(herd1, 100247)
  be _printed holds Output.print(String.from_int(HashSet.size(herd2)))
  return 0
}
```

The answer is 1, and the program prints it. `Output.print` is how it speaks; it prints
text, so the number is turned into a string first, and `main` marks itself `visits
Output` to say plainly that it reaches outside the program. Effects like that are tracked in Yon,
and we will return to them. `100247` stands in for a genome, a value identical in both
adds.
`HashSet.add` does not change the set in place; it returns a new one, the same way `holds`
only ever binds. If you write C or Java, this is the shift that matters: you do not push a
genome into a set, you compute a new state in which the set already contains it. After
adding the same genome twice, the set contains one. Not two collapsed
into one to save space: one, because the second add was the same value, and a
content-addressed set has nowhere to put a second copy of a thing it already has. Change
the second `100247` to a different number and run it again; now it prints two. The
count follows the content, exactly and only.

Hammond would have read this as a bug. He counts births, and two eggs hatching is two.
The set counts content, and two animals from one sequence is one. Neither is lying. They
are answering different questions, and the whole park is the distance between the two
questions.

This is the first half of an identity, and only the first. Two dinosaurs grown from the
same genome are the same thing by content, and the set is right to count them once. But
they are two animals, standing in two places, and you can lose one of them to a fence and
keep the other, which is not something you can do to a single thing. That second half,
the one that lives in *where* and not in *what*, is a later Iteration. For now, hold the
clue: in Yon, to be the same is to be made of the same, and the machine can tell.

There is one last echo, almost too neat to leave out. When this very program was compiled,
the build printed a single quiet line: the structural value numbering pass had collapsed
one operation. It had seen the genome `100247`, written twice in the source, recognized
that both times it was the same value, and kept one. The compiler did to the text of the
program exactly what the program does to the herd: it found two things that were the same
and made them one. Identity by content is not a trick of the set library; it is how the
machine reasons, on the code at compile time and on the heap at run time. It goes all the
way down.

The fractal has been redrawn once. The count, which looked like control, turns out to be
a question nobody in the park had answered.
