# A long answer for the streaming benchmark

This Response mixes every construct Theseus renders: headings, lists, tables, fenced code in two languages, inline and display math, quotes and rules. It is roughly five thousand tokens long.

## 1. Graph search

**Graph search** is a recurring theme in software engineering. In this section we look at the *core idea*, a worked example, and the trade-offs you should keep in mind when you reach for it in production code. The short version: measure first, then optimise the part that actually dominates the runtime, and keep the simple version around as a reference implementation for tests.

Key points:

- The naive approach is usually `O(n²)` and fine for small inputs.
- A better data structure often turns it into `O(n log n)` or `O(n)`.
- Memory layout matters as much as asymptotic complexity on modern CPUs.
- Always keep an eye on the constant factors hidden by big-O notation.

1. Start with a correct, readable version.
2. Write property-based tests against it.
3. Profile with realistic data before changing anything.
4. Replace the hot path, keeping the tests green.

The cost model is easiest to see in math. For input size $n$ the work is $T(n) = 2T(n/2) + O(n)$, which solves to $T(n) = O(n \log n)$. In closed form:

$$
\sum_{k=0}^{\log_2 n} 2^k \cdot \frac{n}{2^k} = n \log_2 n + n
$$

Here is a compact Swift implementation of the idea:

```swift
struct Solver1<Element: Comparable> {
    private var storage: [Element] = []

    mutating func insert(_ element: Element) {
        let index = storage.partitioningIndex { $0 >= element }
        storage.insert(element, at: index)
    }

    func contains(_ element: Element) -> Bool {
        let index = storage.partitioningIndex { $0 >= element }
        return index < storage.count && storage[index] == element
    }
}
```

And the equivalent in Python, for comparison:

```python
def solve_1(items):
    seen = set()
    result = []
    for item in items:  # linear scan
        if item not in seen:
            seen.add(item)
            result.append(item * 1)
    return sorted(result)
```

| Approach | Time | Space | Notes |
|---|---:|---:|---|
| Naive | O(n²) | O(1) | Fine below ~1k items |
| Sorted array | O(n log n) | O(n) | Cache friendly |
| Hash set | O(n) | O(n) | Watch the load factor |
| Tree | O(n log n) | O(n) | Ordered iteration |

> Premature optimisation is the root of much evil, but so is ignoring the profiler when it tells you something obvious.

A final remark on graph search: the inline formula $e^{i\pi} + 1 = 0$ has nothing to do with it, but it is a good test of inline math rendering next to `inline code` and a [link](https://example.com/1).

---

## 2. Dynamic programming

**Dynamic programming** is a recurring theme in software engineering. In this section we look at the *core idea*, a worked example, and the trade-offs you should keep in mind when you reach for it in production code. The short version: measure first, then optimise the part that actually dominates the runtime, and keep the simple version around as a reference implementation for tests.

Key points:

- The naive approach is usually `O(n²)` and fine for small inputs.
- A better data structure often turns it into `O(n log n)` or `O(n)`.
- Memory layout matters as much as asymptotic complexity on modern CPUs.
- Always keep an eye on the constant factors hidden by big-O notation.

1. Start with a correct, readable version.
2. Write property-based tests against it.
3. Profile with realistic data before changing anything.
4. Replace the hot path, keeping the tests green.

The cost model is easiest to see in math. For input size $n$ the work is $T(n) = 2T(n/2) + O(n)$, which solves to $T(n) = O(n \log n)$. In closed form:

$$
\sum_{k=0}^{\log_2 n} 2^k \cdot \frac{n}{2^k} = n \log_2 n + n
$$

Here is a compact Swift implementation of the idea:

```swift
struct Solver2<Element: Comparable> {
    private var storage: [Element] = []

    mutating func insert(_ element: Element) {
        let index = storage.partitioningIndex { $0 >= element }
        storage.insert(element, at: index)
    }

    func contains(_ element: Element) -> Bool {
        let index = storage.partitioningIndex { $0 >= element }
        return index < storage.count && storage[index] == element
    }
}
```

And the equivalent in Python, for comparison:

```python
def solve_2(items):
    seen = set()
    result = []
    for item in items:  # linear scan
        if item not in seen:
            seen.add(item)
            result.append(item * 2)
    return sorted(result)
```

| Approach | Time | Space | Notes |
|---|---:|---:|---|
| Naive | O(n²) | O(1) | Fine below ~1k items |
| Sorted array | O(n log n) | O(n) | Cache friendly |
| Hash set | O(n) | O(n) | Watch the load factor |
| Tree | O(n log n) | O(n) | Ordered iteration |

> Premature optimisation is the root of much evil, but so is ignoring the profiler when it tells you something obvious.

A final remark on dynamic programming: the inline formula $e^{i\pi} + 1 = 0$ has nothing to do with it, but it is a good test of inline math rendering next to `inline code` and a [link](https://example.com/2).

---

## 3. Hashing

**Hashing** is a recurring theme in software engineering. In this section we look at the *core idea*, a worked example, and the trade-offs you should keep in mind when you reach for it in production code. The short version: measure first, then optimise the part that actually dominates the runtime, and keep the simple version around as a reference implementation for tests.

Key points:

- The naive approach is usually `O(n²)` and fine for small inputs.
- A better data structure often turns it into `O(n log n)` or `O(n)`.
- Memory layout matters as much as asymptotic complexity on modern CPUs.
- Always keep an eye on the constant factors hidden by big-O notation.

1. Start with a correct, readable version.
2. Write property-based tests against it.
3. Profile with realistic data before changing anything.
4. Replace the hot path, keeping the tests green.

The cost model is easiest to see in math. For input size $n$ the work is $T(n) = 2T(n/2) + O(n)$, which solves to $T(n) = O(n \log n)$. In closed form:

$$
\sum_{k=0}^{\log_2 n} 2^k \cdot \frac{n}{2^k} = n \log_2 n + n
$$

Here is a compact Swift implementation of the idea:

```swift
struct Solver3<Element: Comparable> {
    private var storage: [Element] = []

    mutating func insert(_ element: Element) {
        let index = storage.partitioningIndex { $0 >= element }
        storage.insert(element, at: index)
    }

    func contains(_ element: Element) -> Bool {
        let index = storage.partitioningIndex { $0 >= element }
        return index < storage.count && storage[index] == element
    }
}
```

And the equivalent in Python, for comparison:

```python
def solve_3(items):
    seen = set()
    result = []
    for item in items:  # linear scan
        if item not in seen:
            seen.add(item)
            result.append(item * 3)
    return sorted(result)
```

| Approach | Time | Space | Notes |
|---|---:|---:|---|
| Naive | O(n²) | O(1) | Fine below ~1k items |
| Sorted array | O(n log n) | O(n) | Cache friendly |
| Hash set | O(n) | O(n) | Watch the load factor |
| Tree | O(n log n) | O(n) | Ordered iteration |

> Premature optimisation is the root of much evil, but so is ignoring the profiler when it tells you something obvious.

A final remark on hashing: the inline formula $e^{i\pi} + 1 = 0$ has nothing to do with it, but it is a good test of inline math rendering next to `inline code` and a [link](https://example.com/3).

---

## 4. Concurrency

**Concurrency** is a recurring theme in software engineering. In this section we look at the *core idea*, a worked example, and the trade-offs you should keep in mind when you reach for it in production code. The short version: measure first, then optimise the part that actually dominates the runtime, and keep the simple version around as a reference implementation for tests.

Key points:

- The naive approach is usually `O(n²)` and fine for small inputs.
- A better data structure often turns it into `O(n log n)` or `O(n)`.
- Memory layout matters as much as asymptotic complexity on modern CPUs.
- Always keep an eye on the constant factors hidden by big-O notation.

1. Start with a correct, readable version.
2. Write property-based tests against it.
3. Profile with realistic data before changing anything.
4. Replace the hot path, keeping the tests green.

The cost model is easiest to see in math. For input size $n$ the work is $T(n) = 2T(n/2) + O(n)$, which solves to $T(n) = O(n \log n)$. In closed form:

$$
\sum_{k=0}^{\log_2 n} 2^k \cdot \frac{n}{2^k} = n \log_2 n + n
$$

Here is a compact Swift implementation of the idea:

```swift
struct Solver4<Element: Comparable> {
    private var storage: [Element] = []

    mutating func insert(_ element: Element) {
        let index = storage.partitioningIndex { $0 >= element }
        storage.insert(element, at: index)
    }

    func contains(_ element: Element) -> Bool {
        let index = storage.partitioningIndex { $0 >= element }
        return index < storage.count && storage[index] == element
    }
}
```

And the equivalent in Python, for comparison:

```python
def solve_4(items):
    seen = set()
    result = []
    for item in items:  # linear scan
        if item not in seen:
            seen.add(item)
            result.append(item * 4)
    return sorted(result)
```

| Approach | Time | Space | Notes |
|---|---:|---:|---|
| Naive | O(n²) | O(1) | Fine below ~1k items |
| Sorted array | O(n log n) | O(n) | Cache friendly |
| Hash set | O(n) | O(n) | Watch the load factor |
| Tree | O(n log n) | O(n) | Ordered iteration |

> Premature optimisation is the root of much evil, but so is ignoring the profiler when it tells you something obvious.

A final remark on concurrency: the inline formula $e^{i\pi} + 1 = 0$ has nothing to do with it, but it is a good test of inline math rendering next to `inline code` and a [link](https://example.com/4).

---

## 5. Numerical methods

**Numerical methods** is a recurring theme in software engineering. In this section we look at the *core idea*, a worked example, and the trade-offs you should keep in mind when you reach for it in production code. The short version: measure first, then optimise the part that actually dominates the runtime, and keep the simple version around as a reference implementation for tests.

Key points:

- The naive approach is usually `O(n²)` and fine for small inputs.
- A better data structure often turns it into `O(n log n)` or `O(n)`.
- Memory layout matters as much as asymptotic complexity on modern CPUs.
- Always keep an eye on the constant factors hidden by big-O notation.

1. Start with a correct, readable version.
2. Write property-based tests against it.
3. Profile with realistic data before changing anything.
4. Replace the hot path, keeping the tests green.

The cost model is easiest to see in math. For input size $n$ the work is $T(n) = 2T(n/2) + O(n)$, which solves to $T(n) = O(n \log n)$. In closed form:

$$
\sum_{k=0}^{\log_2 n} 2^k \cdot \frac{n}{2^k} = n \log_2 n + n
$$

Here is a compact Swift implementation of the idea:

```swift
struct Solver5<Element: Comparable> {
    private var storage: [Element] = []

    mutating func insert(_ element: Element) {
        let index = storage.partitioningIndex { $0 >= element }
        storage.insert(element, at: index)
    }

    func contains(_ element: Element) -> Bool {
        let index = storage.partitioningIndex { $0 >= element }
        return index < storage.count && storage[index] == element
    }
}
```

And the equivalent in Python, for comparison:

```python
def solve_5(items):
    seen = set()
    result = []
    for item in items:  # linear scan
        if item not in seen:
            seen.add(item)
            result.append(item * 5)
    return sorted(result)
```

| Approach | Time | Space | Notes |
|---|---:|---:|---|
| Naive | O(n²) | O(1) | Fine below ~1k items |
| Sorted array | O(n log n) | O(n) | Cache friendly |
| Hash set | O(n) | O(n) | Watch the load factor |
| Tree | O(n log n) | O(n) | Ordered iteration |

> Premature optimisation is the root of much evil, but so is ignoring the profiler when it tells you something obvious.

A final remark on numerical methods: the inline formula $e^{i\pi} + 1 = 0$ has nothing to do with it, but it is a good test of inline math rendering next to `inline code` and a [link](https://example.com/5).

---

## 6. Parsing

**Parsing** is a recurring theme in software engineering. In this section we look at the *core idea*, a worked example, and the trade-offs you should keep in mind when you reach for it in production code. The short version: measure first, then optimise the part that actually dominates the runtime, and keep the simple version around as a reference implementation for tests.

Key points:

- The naive approach is usually `O(n²)` and fine for small inputs.
- A better data structure often turns it into `O(n log n)` or `O(n)`.
- Memory layout matters as much as asymptotic complexity on modern CPUs.
- Always keep an eye on the constant factors hidden by big-O notation.

1. Start with a correct, readable version.
2. Write property-based tests against it.
3. Profile with realistic data before changing anything.
4. Replace the hot path, keeping the tests green.

The cost model is easiest to see in math. For input size $n$ the work is $T(n) = 2T(n/2) + O(n)$, which solves to $T(n) = O(n \log n)$. In closed form:

$$
\sum_{k=0}^{\log_2 n} 2^k \cdot \frac{n}{2^k} = n \log_2 n + n
$$

Here is a compact Swift implementation of the idea:

```swift
struct Solver6<Element: Comparable> {
    private var storage: [Element] = []

    mutating func insert(_ element: Element) {
        let index = storage.partitioningIndex { $0 >= element }
        storage.insert(element, at: index)
    }

    func contains(_ element: Element) -> Bool {
        let index = storage.partitioningIndex { $0 >= element }
        return index < storage.count && storage[index] == element
    }
}
```

And the equivalent in Python, for comparison:

```python
def solve_6(items):
    seen = set()
    result = []
    for item in items:  # linear scan
        if item not in seen:
            seen.add(item)
            result.append(item * 6)
    return sorted(result)
```

| Approach | Time | Space | Notes |
|---|---:|---:|---|
| Naive | O(n²) | O(1) | Fine below ~1k items |
| Sorted array | O(n log n) | O(n) | Cache friendly |
| Hash set | O(n) | O(n) | Watch the load factor |
| Tree | O(n log n) | O(n) | Ordered iteration |

> Premature optimisation is the root of much evil, but so is ignoring the profiler when it tells you something obvious.

A final remark on parsing: the inline formula $e^{i\pi} + 1 = 0$ has nothing to do with it, but it is a good test of inline math rendering next to `inline code` and a [link](https://example.com/6).

---

## 7. Caching

**Caching** is a recurring theme in software engineering. In this section we look at the *core idea*, a worked example, and the trade-offs you should keep in mind when you reach for it in production code. The short version: measure first, then optimise the part that actually dominates the runtime, and keep the simple version around as a reference implementation for tests.

Key points:

- The naive approach is usually `O(n²)` and fine for small inputs.
- A better data structure often turns it into `O(n log n)` or `O(n)`.
- Memory layout matters as much as asymptotic complexity on modern CPUs.
- Always keep an eye on the constant factors hidden by big-O notation.

1. Start with a correct, readable version.
2. Write property-based tests against it.
3. Profile with realistic data before changing anything.
4. Replace the hot path, keeping the tests green.

The cost model is easiest to see in math. For input size $n$ the work is $T(n) = 2T(n/2) + O(n)$, which solves to $T(n) = O(n \log n)$. In closed form:

$$
\sum_{k=0}^{\log_2 n} 2^k \cdot \frac{n}{2^k} = n \log_2 n + n
$$

Here is a compact Swift implementation of the idea:

```swift
struct Solver7<Element: Comparable> {
    private var storage: [Element] = []

    mutating func insert(_ element: Element) {
        let index = storage.partitioningIndex { $0 >= element }
        storage.insert(element, at: index)
    }

    func contains(_ element: Element) -> Bool {
        let index = storage.partitioningIndex { $0 >= element }
        return index < storage.count && storage[index] == element
    }
}
```

And the equivalent in Python, for comparison:

```python
def solve_7(items):
    seen = set()
    result = []
    for item in items:  # linear scan
        if item not in seen:
            seen.add(item)
            result.append(item * 7)
    return sorted(result)
```

| Approach | Time | Space | Notes |
|---|---:|---:|---|
| Naive | O(n²) | O(1) | Fine below ~1k items |
| Sorted array | O(n log n) | O(n) | Cache friendly |
| Hash set | O(n) | O(n) | Watch the load factor |
| Tree | O(n log n) | O(n) | Ordered iteration |

> Premature optimisation is the root of much evil, but so is ignoring the profiler when it tells you something obvious.

A final remark on caching: the inline formula $e^{i\pi} + 1 = 0$ has nothing to do with it, but it is a good test of inline math rendering next to `inline code` and a [link](https://example.com/7).

---

## 8. Compression

**Compression** is a recurring theme in software engineering. In this section we look at the *core idea*, a worked example, and the trade-offs you should keep in mind when you reach for it in production code. The short version: measure first, then optimise the part that actually dominates the runtime, and keep the simple version around as a reference implementation for tests.

Key points:

- The naive approach is usually `O(n²)` and fine for small inputs.
- A better data structure often turns it into `O(n log n)` or `O(n)`.
- Memory layout matters as much as asymptotic complexity on modern CPUs.
- Always keep an eye on the constant factors hidden by big-O notation.

1. Start with a correct, readable version.
2. Write property-based tests against it.
3. Profile with realistic data before changing anything.
4. Replace the hot path, keeping the tests green.

The cost model is easiest to see in math. For input size $n$ the work is $T(n) = 2T(n/2) + O(n)$, which solves to $T(n) = O(n \log n)$. In closed form:

$$
\sum_{k=0}^{\log_2 n} 2^k \cdot \frac{n}{2^k} = n \log_2 n + n
$$

Here is a compact Swift implementation of the idea:

```swift
struct Solver8<Element: Comparable> {
    private var storage: [Element] = []

    mutating func insert(_ element: Element) {
        let index = storage.partitioningIndex { $0 >= element }
        storage.insert(element, at: index)
    }

    func contains(_ element: Element) -> Bool {
        let index = storage.partitioningIndex { $0 >= element }
        return index < storage.count && storage[index] == element
    }
}
```

And the equivalent in Python, for comparison:

```python
def solve_8(items):
    seen = set()
    result = []
    for item in items:  # linear scan
        if item not in seen:
            seen.add(item)
            result.append(item * 8)
    return sorted(result)
```

| Approach | Time | Space | Notes |
|---|---:|---:|---|
| Naive | O(n²) | O(1) | Fine below ~1k items |
| Sorted array | O(n log n) | O(n) | Cache friendly |
| Hash set | O(n) | O(n) | Watch the load factor |
| Tree | O(n log n) | O(n) | Ordered iteration |

> Premature optimisation is the root of much evil, but so is ignoring the profiler when it tells you something obvious.

A final remark on compression: the inline formula $e^{i\pi} + 1 = 0$ has nothing to do with it, but it is a good test of inline math rendering next to `inline code` and a [link](https://example.com/8).

---

That's the end of the benchmark document.
