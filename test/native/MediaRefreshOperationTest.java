package com.example.image_tag_manager;
import java.util.*;
public final class MediaRefreshOperationTest {
    static final class Fake implements MediaRefreshOperation.Backend {
        Set<String> names = new HashSet<>(); List<String> scanned = new ArrayList<>(); int queries;
        boolean complete = true;
        public Set<String> indexed(List<String> paths) { queries++; return new HashSet<>(names); }
        public boolean scan(List<String> paths) { scanned.addAll(paths); if (complete) names.addAll(paths); return complete; }
    }
    static void check(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) {
        Fake upToDate = new Fake(); upToDate.names.addAll(List.of("a", "b"));
        check(MediaRefreshOperation.refresh(List.of("a", "b", "a"), upToDate));
        check(upToDate.scanned.isEmpty() && upToDate.queries == 1);
        Fake repair = new Fake(); repair.names.add("a");
        check(MediaRefreshOperation.refresh(List.of("a", "b", "b"), repair));
        check(repair.scanned.equals(List.of("b")) && repair.queries == 2);
        Fake timeout = new Fake(); timeout.complete = false;
        check(!MediaRefreshOperation.refresh(List.of("b"), timeout));
        Fake empty = new Fake(); check(MediaRefreshOperation.refresh(List.of(), empty)); check(empty.queries == 0);
        System.out.println("4 media refresh scenarios passed: no redundant scan, targeted repair, timeout and empty batch.");
    }
}
