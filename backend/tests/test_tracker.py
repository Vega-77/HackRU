from cv_engine.detect import Detection
from cv_engine.tracker import CentroidTracker


def det(x, y, label="red"):
    return Detection(label, (x, y), (int(x) - 10, int(y) - 10, 20, 20), 300.0, 1.0, "color")


def test_ids_stay_stable_while_objects_move():
    tr = CentroidTracker(min_hits=1)
    first = tr.update([det(100, 100), det(400, 100)])
    ids = {round(t.centroid[0]): t.id for t in first}
    for step in range(1, 20):
        tracks = tr.update([det(100 + 15 * step, 100), det(400 - 5 * step, 100)])
        by_id = {t.id: t.centroid[0] for t in tracks}
        assert by_id[ids[100]] == 100 + 15 * step
        assert by_id[ids[400]] == 400 - 5 * step


def test_fast_object_followed_using_prediction():
    tr = CentroidTracker(max_distance=40, min_hits=1)
    tid = tr.update([det(0, 200)])[0].id
    for step in range(1, 10):
        # 60 px/frame is beyond max_distance, but the constant-velocity prediction covers it
        # once the motion is known (after the first, slower step).
        x = 30 if step == 1 else 30 + 60 * (step - 1)
        tracks = tr.update([det(x, 200)])
        assert [t.id for t in tracks] == [tid]


def test_short_occlusion_keeps_id_and_long_one_drops_it():
    tr = CentroidTracker(max_missed=3, min_hits=1)
    tid = tr.update([det(100, 100)])[0].id
    tr.update([det(110, 100)])
    for _ in range(3):
        assert tr.update([]) == []
    assert tr.update([det(150, 100)])[0].id == tid  # predicted ~150 after 3 missed frames
    for _ in range(4):
        tr.update([])
    assert tid not in tr.tracks


def test_labels_never_swap():
    tr = CentroidTracker(min_hits=1)
    tr.update([det(100, 100, "red"), det(120, 100, "blue")])
    tracks = tr.update([det(120, 100, "red"), det(100, 100, "blue")])
    assert {t.label for t in tracks} == {"red", "blue"}
    assert len(tr.tracks) == 2


def test_new_tracks_need_min_hits():
    tr = CentroidTracker(min_hits=2)
    assert tr.update([det(100, 100)]) == []
    assert len(tr.update([det(102, 100)])) == 1
