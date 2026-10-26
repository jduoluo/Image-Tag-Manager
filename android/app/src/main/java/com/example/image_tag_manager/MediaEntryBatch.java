package com.example.image_tag_manager;

import java.util.*;
import java.util.function.*;

/** Bounded IN queries with strict completeness and stable requested-ID ordering. */
final class MediaEntryBatch {
    static <T> void forEach(List<Long> ids, int limit,
            Function<List<Long>, Map<Long, T>> query, BiConsumer<Long, T> consume, Runnable checkCancelled) {
        if (limit < 1 || new HashSet<>(ids).size() != ids.size()) {
            throw new IllegalStateException("所选图片 ID 重复或批次大小无效");
        }
        for (int offset = 0; offset < ids.size(); offset += limit) {
            checkCancelled.run();
            List<Long> batch = ids.subList(offset, Math.min(ids.size(), offset + limit));
            Map<Long, T> rows = query.apply(batch);
            if (rows == null || !rows.keySet().equals(new HashSet<>(batch))) {
                throw new IllegalStateException("部分图片已不存在或不可访问，请重新选择");
            }
            for (Long id : batch) {
                checkCancelled.run();
                if (rows.get(id) == null) throw new IllegalStateException("媒体记录为空");
                consume.accept(id, rows.get(id));
            }
        }
    }
}
