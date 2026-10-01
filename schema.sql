-- 频点协调服务数据库结构
-- 应用启动时自动执行（幂等），无需手工初始化。

CREATE TABLE IF NOT EXISTS sessions (
    id           SERIAL PRIMARY KEY,
    name         TEXT NOT NULL,
    frequencies  INTEGER[] NOT NULL,          -- 场次可用的整数频点集合（升序、去重）
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS groups (
    id           SERIAL PRIMARY KEY,          -- 组编号（自增，规划时按此升序）
    session_id   INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    name         TEXT NOT NULL DEFAULT '',
    start_min    INTEGER NOT NULL,            -- 使用时段起点（分钟，左闭）
    end_min      INTEGER NOT NULL,            -- 使用时段终点（分钟，右开）
    -- 该组设备实际可调谐的频点集合：NULL 表示录入时未填写，视为支持场次全部
    -- 可用频点；非空时须是场次可用频点的非空子集（子集由应用层校验）。
    supported_frequencies INTEGER[],
    -- 组支持集合的配置修订号：录入即为 1，每次按组变更支持集合递增 1；
    -- 变更必须携带所见修订号，过期提交拒绝（乐观并发控制）。
    config_revision INTEGER NOT NULL DEFAULT 1,
    CHECK (start_min < end_min),
    CHECK (supported_frequencies IS NULL
           OR cardinality(supported_frequencies) > 0)
);

-- 既有库幂等升级：补列（全新库建表已含则跳过）。
ALTER TABLE groups ADD COLUMN IF NOT EXISTS supported_frequencies INTEGER[];
ALTER TABLE groups ADD COLUMN IF NOT EXISTS config_revision INTEGER NOT NULL DEFAULT 1;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'groups_supported_nonempty'
    ) THEN
        ALTER TABLE groups
            ADD CONSTRAINT groups_supported_nonempty
            CHECK (supported_frequencies IS NULL
                   OR cardinality(supported_frequencies) > 0);
    END IF;
END$$;

CREATE TABLE IF NOT EXISTS interferences (
    id             SERIAL PRIMARY KEY,
    session_id     INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    group_a        INTEGER NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    group_b        INTEGER NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    min_separation INTEGER NOT NULL,          -- 正整数最小频点间距
    CHECK (group_a <> group_b),
    CHECK (min_separation > 0)
);

-- 发布版：每个场次内版本号从 1 单调递增，发布后不可变
CREATE TABLE IF NOT EXISTS plans (
    id           SERIAL PRIMARY KEY,
    session_id   INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    version      INTEGER NOT NULL,
    changes      INTEGER NOT NULL,            -- 相对前一发布版共有组的改频数
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (session_id, version)
);

CREATE TABLE IF NOT EXISTS plan_assignments (
    plan_id      INTEGER NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
    group_id     INTEGER NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    frequency    INTEGER NOT NULL,
    PRIMARY KEY (plan_id, group_id)
);

-- 规划时使用的锁定（随发布版留存，便于追溯）
CREATE TABLE IF NOT EXISTS plan_locks (
    plan_id      INTEGER NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
    group_id     INTEGER NOT NULL,
    frequency    INTEGER NOT NULL,
    PRIMARY KEY (plan_id, group_id)
);

-- 外部设备占用记录：场次频点在指定整数分钟时段 [start, end) 被其他设备占用。
-- 设备组时段与占用时段相交（左闭右开，端点相接不算相交）时不得选用该频点。
CREATE TABLE IF NOT EXISTS occupations (
    id           SERIAL PRIMARY KEY,
    session_id   INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    frequency    INTEGER NOT NULL,            -- 被占用的频点（须属于场次可用集合）
    start_min    INTEGER NOT NULL,            -- 占用起点（分钟，左闭）
    end_min      INTEGER NOT NULL,            -- 占用终点（分钟，右开）
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (start_min < end_min)
);

CREATE INDEX IF NOT EXISTS idx_occupations_session
    ON occupations (session_id);

-- 实测频点批次：现场对某场次一次完整实测的留档（提交后不可变）。
-- 批次号在场次内递增；内容指纹用于同批次重试的幂等判定与内容冲突拒绝；
-- occupation_snapshot 固化提交时的当前占用，后续撤销占用不改变历史核对结果。
CREATE TABLE IF NOT EXISTS measurements (
    id                  SERIAL PRIMARY KEY,
    session_id          INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    batch_no            INTEGER NOT NULL,        -- 场次内递增批次号（>=1）
    plan_version        INTEGER NOT NULL,        -- 核对所依据的指定发布版号
    content_fingerprint JSONB NOT NULL,          -- 提交内容指纹（批次幂等/冲突判定）
    occupation_snapshot JSONB NOT NULL,          -- 提交时的当前占用快照（判定依据固化）
    result              JSONB NOT NULL,          -- 固化的核对结果
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (batch_no >= 1),
    UNIQUE (session_id, batch_no)
);

-- 批次内每个设备组的实测整数频点（即使不在场次可用集合内也如实留存）
CREATE TABLE IF NOT EXISTS measurement_readings (
    measurement_id INTEGER NOT NULL REFERENCES measurements(id) ON DELETE CASCADE,
    group_id       INTEGER NOT NULL,
    frequency      INTEGER NOT NULL,
    PRIMARY KEY (measurement_id, group_id)
);

CREATE INDEX IF NOT EXISTS idx_measurements_session
    ON measurements (session_id, batch_no);
