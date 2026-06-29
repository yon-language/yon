<!-- DRAFT — the genome / Golay error correction (VoyagerList). JP scene: Wu's gap-filling.
     Code: VoyagerList seal/corrupt/recover (CODE ✓ NATIVE-GATED 2026-06-27, stdout 1445; built from verified pieces:
     VoyagerList.empty/append/get/corrupt_at exist (emit_mlir.ml:488-493); Golay correct
     proven in runtime/test_unit_voyagerlist.c). SHORT LEASH: Yon does not "repair DNA".
     Style: no em-dashes; reserved words stay keywords; reader-facing verdict. -->

# The Genome, Retouched

## The scene

Wu shows them the lab where the dinosaurs are made. The DNA comes from insects trapped in
amber, and it comes in fragments, with gaps where time ate the strands. To make a whole
animal you must fill the gaps, and Wu fills them with what he has: pieces of frog, of bird,
of reptile, best guesses spliced into the holes. He is proud of it. The animals carry
version numbers, 4.1, 4.3, 4.4, like software, because each time the lab finds a bad join
it ships a new cut. Grant asks what is real in an animal assembled this way, and Wu has no
answer, because the question has none. The gaps were filled to look right, not to be right.
And one of those frog-shaped guesses, the book will later learn, is why the animals that
cannot breed are breeding.

## The idea

There are two ways to face a damaged message, and the park is the story of choosing the
wrong one.

**On the philosophical plane.** Integrity can be a property of the data itself, not a guard
bolted onto it. A checksum tells you something broke. A code lets you put it back, because
the legal messages are spread far enough apart that a damaged one still has exactly one
nearest neighbour. Correction stops being a repair and becomes a decoding: you do not guess
what was meant, you compute it.

**In the language.** Yon's `VoyagerList` is such a code, Golay (24,12,8). A number sealed
into it is carried as 24 bits, of which 12 are data, and the legal codewords are at least 8
apart. Flip one bit, or two, or three, and the result is still closer to the original than
to any other codeword, so opening it returns the number whole. The corruption is not
repaired by hand; it is decoded away.

**On the silicon.** This is not a toy code. Golay (24,12,8) is the code Voyager carried, the
one that sent photographs of Jupiter and Saturn back across the solar system through
deep-space noise that would have shredded a plain signal. The same structure that recovered
a picture of a moon from a billion kilometres of static recovers a gene from a flipped bit.

## The code

Seal a gene, corrupt two of its bits, and read it back. It comes back whole.

```yon
fun main(): number visits Output {
  be genome holds VoyagerList.empty()
  be g1 holds VoyagerList.append(genome, 1445)      // a gene, sealed as a Golay codeword
  be damaged holds VoyagerList.corrupt_at(g1, 0, 2)  // two bits flipped, as in a bad join
  be read holds VoyagerList.get(damaged, 0)          // opening is decoding
  be _ holds Output.print(String.from_int(read))     // 1445, recovered
  return 0
}
```

`append` seals the number into a codeword. `corrupt_at` flips two of its bits, the kind of
damage a bad join leaves behind. `get` opens the codeword, and opening is decoding: Golay's
distance of 8 leaves room for up to three errors, so two flipped bits still decode to the
gene that was sealed. The printed line is `1445`, the number we put in, returned through the
damage.

## The short leash

This is an analogy, and it has a limit the book will not cross. Yon does not repair DNA, and
it does not claim to. What it shows is the difference between InGen's kind of correction and
a code's. InGen filled the gaps with guesses chosen to look like an animal, and a guess that
looks right can be wrong in a way nothing detects until it breeds. A code does not guess. It
decodes to the one message its structure allows, or, past its limit, it fails rather than
inventing. The lesson is the shape of the two, not a promise that Golay would have saved the
park. The frog DNA was not noise on a good signal; it was a wrong signal sent on purpose, and
no decoder corrects that. What Yon offers is the other path: when integrity is built into the
data as structure, recovery is a computation, not a hope.

## What holds

Golay (24,12,8) is verified. `runtime/test_unit_voyagerlist.c` seals every 12-bit value and
opens it back exactly, then corrupts one and two bits of a codeword and confirms it still
decodes to the original (distance 8 corrects up to three errors). The program above is built
from the same pieces (`VoyagerList.empty` / `append` / `corrupt_at` / `get`); build it with
`toolchain/yonc` and it prints `1445`, the gene returned through two flipped bits.

<!-- WEBSITE: the GENOME player (the second recorded visualization) belongs here: show the
     24-bit codeword, flip 1-2 bits visibly, then decode to the recovered datum. -->
