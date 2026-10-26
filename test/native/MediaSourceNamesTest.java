package com.example.image_tag_manager;

import java.util.*;

public final class MediaSourceNamesTest {
    static void check(boolean value) { if (!value) throw new AssertionError(); }
    static void reject(Runnable work, String message) {
        try { work.run(); } catch (IllegalStateException error) {
            check(error.getMessage().contains(message)); return;
        }
        throw new AssertionError("Unexpected success");
    }
    public static void main(String[] args) {
        MediaSourceNames exact = new MediaSourceNames(Arrays.asList("a.png"));
        check(exact.resolve("a.png", "a.png", "id", name -> { throw new AssertionError("unnecessary identity read"); }).equals("a.png"));
        MediaSourceNames upper = new MediaSourceNames(Arrays.asList("a.PNG"));
        check(upper.resolve("a.png", "a.png", "id", name -> "id").equals("a.PNG"));
        check(upper.resolve("a.png", "a.PNG", "id", name -> { throw new AssertionError("unnecessary identity read"); }).equals("a.PNG"));
        reject(() -> upper.resolve("a.png", "a.png", "id", name -> "replacement"), "身份不一致");
        reject(() -> upper.resolve("other.png", "a.png", "id", name -> "id"), "名称与路径不一致");
        reject(() -> new MediaSourceNames(Collections.emptyList()).resolve("missing.png", "missing.png", "id", name -> "id"), "未找到");
        reject(() -> new MediaSourceNames(Arrays.asList("a.PNG", "A.png")).resolve("a.png", "a.png", "id", name -> "id"), "多个同身份");
        MediaSourceNames hidden = new MediaSourceNames(Collections.emptyList());
        check(hidden.resolve("hidden.png", "hidden.png", "id", name -> null,
            name -> "id").equals("hidden.png"));
        reject(() -> hidden.resolve("hidden.png", "hidden.png", "id", name -> null,
            name -> "replacement"), "未找到");
        reject(() -> hidden.resolve("hidden.png", "hidden.png", "id", name -> null,
            name -> null), "未找到");
        reject(() -> hidden.resolve("hidden.PNG", "hidden.png", "id", name -> null,
            name -> { throw new AssertionError("unknown actual spelling accepted"); }), "未找到");
        reject(() -> upper.resolve("a.png", "a.png", "id", name -> "other",
            name -> { throw new AssertionError("visible conflict bypassed"); }), "身份不一致");
        System.out.println("12 media source-name scenarios passed (host fixtures).");
    }
}
