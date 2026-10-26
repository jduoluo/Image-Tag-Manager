package com.example.image_tag_manager;

import java.util.*;
import java.util.concurrent.CancellationException;

public final class MediaEntryBatchTest {
    static void check(boolean accepted) { if (!accepted) throw new AssertionError(); }
    static void rejects(Runnable work) {
        try { work.run(); } catch (IllegalStateException error) { return; }
        throw new AssertionError("Unexpected success");
    }
    public static void main(String[] args) {
        List<Long> ids = new ArrayList<>();
        for (long id = 0; id < 3001; id++) ids.add(id);
        List<Long> consumed = new ArrayList<>();
        List<Integer> sizes = new ArrayList<>();
        MediaEntryBatch.forEach(ids, 300, batch -> {
            sizes.add(batch.size());
            Map<Long, Long> rows = new LinkedHashMap<>();
            for (int i = batch.size() - 1; i >= 0; i--) rows.put(batch.get(i), batch.get(i));
            return rows;
        }, (id, value) -> { check(id.equals(value)); consumed.add(id); }, () -> {});
        check(sizes.size() == 11 && sizes.get(10) == 1 && consumed.equals(ids));
        rejects(() -> MediaEntryBatch.forEach(Arrays.asList(1L, 1L), 300,
            batch -> { throw new AssertionError("query for duplicate IDs"); }, (id, row) -> {}, () -> {}));
        rejects(() -> MediaEntryBatch.forEach(Arrays.asList(1L, 2L), 300,
            batch -> Collections.singletonMap(1L, "row"), (id, row) -> { throw new AssertionError("incomplete batch consumed"); }, () -> {}));
        rejects(() -> MediaEntryBatch.forEach(Arrays.asList(1L), 300,
            batch -> Collections.singletonMap(2L, "wrong"), (id, row) -> { throw new AssertionError("wrong ID consumed"); }, () -> {}));
        int[] reads = {0}; int[] processed = {0};
        try {
            MediaEntryBatch.forEach(ids, 300, batch -> {
                reads[0]++; Map<Long, Long> rows = new HashMap<>();
                for (Long id : batch) rows.put(id, id); return rows;
            }, (id, value) -> processed[0]++, () -> {
                if (processed[0] == 50) throw new CancellationException();
            });
            throw new AssertionError("Cancellation ignored");
        } catch (CancellationException expected) { check(reads[0] == 1 && processed[0] == 50); }
        MediaEntryBatch.forEach(Collections.emptyList(), 300,
            batch -> { throw new AssertionError("empty selection queried"); }, (id, row) -> {}, () -> {});
        System.out.println("6 batched media-query scenarios passed (3001 fixture IDs).");
    }
}
