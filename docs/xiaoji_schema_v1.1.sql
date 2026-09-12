-- =====================================================================
-- 校集 校园二手交易+社区小程序  数据库建表脚本 v1.1（评审修复版）
-- MySQL 8.0+ | utf8mb4 | InnoDB | 数据库名: xiaoji
--
-- 【v1.0 -> v1.1 变更说明】(评审: 2026-09-12)
--  1. xj_users.phone         VARCHAR(20) -> VARCHAR(128)：加密存储后密文(base64/SM4)远超20字符
--  2. xj_conversations       user_a/user_b 改为可空：群聊双方=0时第二条群聊必撞 uk_pair 唯一键
--                            (MySQL 唯一索引对 NULL 不去重，群聊两列置 NULL 即可共存)
--  3. xj_posts.status        语义修正: 0待审 1正常 2下架 3删除，DEFAULT 0
--                            (原 v1.0 注释 0正常/1待审 但 DEFAULT 1，新帖全部默认进人工审核，
--                             与"敏感词机审→AI审核→人工抽检"的分层设计矛盾)
--  4. xj_orders              新增 goods_title / goods_cover 快照字段：
--                            商品可被编辑/下架/删除，订单详情不能因此断链
--  5. xj_orders              新增 verify_refresh_at：核销码"10分钟刷新"需要落库刷新时间，
--                            否则扫码端无法校验码是否在有效期
--  6. xj_platform_config     新增 publish_require_auth(发布需校园认证开关)：
--                            信用分门槛(40)不能单独作为发布条件——游客初始70分若只看分数即可发布，
--                            必须同时校验 auth_status=2 已认证
--  7. 新增 verify_code_refresh_sec 配置：核销码刷新周期参数化
--
-- 【分库分表策略】(容量估算: 50 校/75 万潜在用户/峰值 5000 QPS)
--   xj_orders     : 按 buyer_id 哈希 16 库 x 16 表 (buyer_id%16 定位库, buyer_id/16%16 定位表)
--   xj_posts      : 按 school_id + 年月 月表 (例: xj_posts_202609)
--   xj_messages   : 按 conversation_id 哈希 64 分表
--   xj_ad_bills   : 按 年月 月表 (广告扣费流水量大)
--   其余表: 单库单表 + 主从读写分离; 热点数据走 Redis 缓存
-- 本脚本按单库版建表, 分片时 DDL 结构不变, 仅按策略落不同物理表
-- =====================================================================

CREATE DATABASE IF NOT EXISTS xiaoji DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
USE xiaoji;

-- ---------------------------------------------------------------------
-- 1. 学校库
-- ---------------------------------------------------------------------
CREATE TABLE xj_schools (
  id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  name          VARCHAR(64)  NOT NULL COMMENT '学校名称',
  city          VARCHAR(32)  NOT NULL DEFAULT '' COMMENT '所在城市',
  alias         VARCHAR(64)  NOT NULL DEFAULT '' COMMENT '简称/别名',
  open_month    TINYINT      NOT NULL DEFAULT 9  COMMENT '开学月',
  graduate_month TINYINT     NOT NULL DEFAULT 6  COMMENT '毕业月',
  status        TINYINT      NOT NULL DEFAULT 1  COMMENT '1启用 0停用',
  created_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uk_name (name)
) ENGINE=InnoDB COMMENT='学校库';

-- ---------------------------------------------------------------------
-- 2. 用户表
-- ---------------------------------------------------------------------
CREATE TABLE xj_users (
  id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  openid          VARCHAR(64)  NOT NULL COMMENT '微信 openid',
  unionid         VARCHAR(64)  NOT NULL DEFAULT '' COMMENT '微信 unionid',
  phone           VARCHAR(128) NOT NULL DEFAULT '' COMMENT '手机号(SM4/AES加密存储, 密文长度>20)',
  nickname        VARCHAR(32)  NOT NULL DEFAULT '' COMMENT '昵称',
  avatar          VARCHAR(255) NOT NULL DEFAULT '' COMMENT '头像 URL',
  school_id       BIGINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '认证学校, 0=未认证',
  auth_status     TINYINT      NOT NULL DEFAULT 0 COMMENT '0游客 1认证中 2已认证 3驳回 4校友(毕业降级)',
  real_name       VARCHAR(32)  NOT NULL DEFAULT '' COMMENT '真实姓名(仅认证比对, 永不展示)',
  student_no      VARCHAR(32)  NOT NULL DEFAULT '' COMMENT '学号(仅认证比对, 永不展示)',
  credit_score    INT          NOT NULL DEFAULT 70 COMMENT '信用分 0-150, 低于40禁发布/禁担保交易',
  status          TINYINT      NOT NULL DEFAULT 0 COMMENT '0正常 1禁言 2封号',
  graduation_date DATE         NULL COMMENT '毕业日期, 定时任务到期自动降级校友',
  created_at      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uk_openid (openid),
  KEY idx_school (school_id, auth_status),
  KEY idx_credit (credit_score)
) ENGINE=InnoDB COMMENT='用户表';

-- ---------------------------------------------------------------------
-- 3. 校园认证记录
-- ---------------------------------------------------------------------
CREATE TABLE xj_user_auth (
  id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id       BIGINT UNSIGNED NOT NULL,
  auth_type     TINYINT      NOT NULL COMMENT '1学号+姓名核验 2学生证OCR 3校园邮箱',
  school_id     BIGINT UNSIGNED NOT NULL,
  proof_url     VARCHAR(255) NOT NULL DEFAULT '' COMMENT '学生证照片/截图 URL',
  status        TINYINT      NOT NULL DEFAULT 0 COMMENT '0待审 1通过 2驳回',
  auditor_id    BIGINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '审核人(后台用户)',
  audit_time    DATETIME     NULL,
  reject_reason VARCHAR(255) NOT NULL DEFAULT '',
  created_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_user (user_id),
  KEY idx_status (status, created_at)
) ENGINE=InnoDB COMMENT='校园认证记录';

-- ---------------------------------------------------------------------
-- 4. 信用分流水
-- ---------------------------------------------------------------------
CREATE TABLE xj_credit_log (
  id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id       BIGINT UNSIGNED NOT NULL,
  score_change  INT          NOT NULL COMMENT '变动分值, 正加负减',
  reason_code   VARCHAR(32)  NOT NULL COMMENT 'TRADE_OK交易履约+50/COMPLAINT被投诉-30/VERDICT_LOSE仲裁判负-50/CERT实名+20/OTHER',
  biz_id        BIGINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '关联订单/案件ID',
  created_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_user (user_id, created_at)
) ENGINE=InnoDB COMMENT='信用分流水';

-- ---------------------------------------------------------------------
-- 5. 商品表
-- ---------------------------------------------------------------------
CREATE TABLE xj_goods (
  id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  seller_id       BIGINT UNSIGNED NOT NULL,
  school_id       BIGINT UNSIGNED NOT NULL COMMENT '卖家学校(同校优先展示)',
  category        VARCHAR(32)  NOT NULL COMMENT '教材/数码/生活/美妆/运动/票券/服饰/乐器/其他',
  title           VARCHAR(64)  NOT NULL,
  description     TEXT         NOT NULL COMMENT '商品描述(进ES全文检索)',
  condition_grade TINYINT      NOT NULL DEFAULT 3 COMMENT '成色 1全新 2几乎全新 3轻微使用 4明显使用 5配件级',
  price           DECIMAL(10,2) NOT NULL COMMENT '售价(元)',
  negotiable      TINYINT      NOT NULL DEFAULT 1 COMMENT '1可议价 0一口价',
  trade_type      TINYINT      NOT NULL DEFAULT 1 COMMENT '1校内面交 2自提 3快递',
  freight_tpl     TINYINT      NOT NULL DEFAULT 2 COMMENT '运费模板 0包邮 1按件 2到付',
  freight_fee     DECIMAL(10,2) NOT NULL DEFAULT 0 COMMENT '按件运费(元)',
  commission_rate DECIMAL(5,2) NOT NULL DEFAULT 3.00 COMMENT '佣金率快照(下单时冻结, 取平台配置)',
  is_video        TINYINT      NOT NULL DEFAULT 0 COMMENT '1短视频挂车',
  video_id        BIGINT UNSIGNED NOT NULL DEFAULT 0,
  status          TINYINT      NOT NULL DEFAULT 4 COMMENT '0在售 1交易锁定 2已售 3下架 4审核中 5审核驳回',
  exposure_count  INT          NOT NULL DEFAULT 0 COMMENT '曝光数(Redis计数异步落库)',
  created_at      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_seller (seller_id, status),
  KEY idx_school_cate (school_id, category, status),
  KEY idx_price (price)
) ENGINE=InnoDB COMMENT='商品表(二手集市)';

-- ---------------------------------------------------------------------
-- 6. 商品图片
-- ---------------------------------------------------------------------
CREATE TABLE xj_goods_images (
  id        BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  goods_id  BIGINT UNSIGNED NOT NULL,
  url       VARCHAR(255) NOT NULL COMMENT 'OSS URL(缩略图+原图)',
  sort      INT          NOT NULL DEFAULT 0,
  PRIMARY KEY (id),
  KEY idx_goods (goods_id)
) ENGINE=InnoDB COMMENT='商品图片';

-- ---------------------------------------------------------------------
-- 7. 商品收藏
-- ---------------------------------------------------------------------
CREATE TABLE xj_goods_collections (
  id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id    BIGINT UNSIGNED NOT NULL,
  goods_id   BIGINT UNSIGNED NOT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uk_user_goods (user_id, goods_id)
) ENGINE=InnoDB COMMENT='商品收藏';

-- ---------------------------------------------------------------------
-- 8. 订单表 [分库分表: buyer_id 哈希 16x16]
-- ---------------------------------------------------------------------
CREATE TABLE xj_orders (
  id               BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  order_no         VARCHAR(32)  NOT NULL COMMENT '业务单号',
  buyer_id         BIGINT UNSIGNED NOT NULL COMMENT '分片键',
  seller_id        BIGINT UNSIGNED NOT NULL,
  goods_id         BIGINT UNSIGNED NOT NULL,
  goods_title      VARCHAR(64)  NOT NULL DEFAULT '' COMMENT '商品标题快照(下单时冻结, 防商品编辑/下架后断链)',
  goods_cover      VARCHAR(255) NOT NULL DEFAULT '' COMMENT '商品主图快照(OSS URL)',
  amount           DECIMAL(10,2) NOT NULL COMMENT '商品金额(元)',
  freight_fee      DECIMAL(10,2) NOT NULL DEFAULT 0 COMMENT '运费(元)',
  commission_rate  DECIMAL(5,2) NOT NULL COMMENT '佣金率快照(下单冻结, 成交后按此计提)',
  commission_amount DECIMAL(10,2) NOT NULL DEFAULT 0 COMMENT '佣金金额(确认收货后计提)',
  status           TINYINT      NOT NULL DEFAULT 10 COMMENT '10待付款 20已付款待交付 30已交付待确认 40已完成 50退款中 51已退款 60仲裁中 61已判决 90已关闭',
  trade_type       TINYINT      NOT NULL COMMENT '1面交 2自提 3快递',
  verify_code      VARCHAR(6)   NOT NULL DEFAULT '' COMMENT '面交核销码(6位)',
  verify_refresh_at DATETIME    NULL COMMENT '核销码刷新时间(默认10分钟一刷, 扫码端校验有效期)',
  verify_status    TINYINT      NOT NULL DEFAULT 0 COMMENT '核销状态 0未核销 1已核销',
  pay_expire_at    DATETIME     NULL COMMENT '待付款超时(24h自动关单)',
  auto_confirm_at  DATETIME     NULL COMMENT '自动确认收货时间(快递10天/面交核销后24h)',
  buyer_confirm_at DATETIME     NULL,
  created_at       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uk_order_no (order_no),
  KEY idx_buyer (buyer_id, status),
  KEY idx_seller (seller_id, status),
  KEY idx_expire (pay_expire_at),
  KEY idx_autoconfirm (auto_confirm_at)
) ENGINE=InnoDB COMMENT='订单表(担保交易)';

-- ---------------------------------------------------------------------
-- 9. 订单状态日志
-- ---------------------------------------------------------------------
CREATE TABLE xj_order_logs (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  order_id    BIGINT UNSIGNED NOT NULL,
  from_status TINYINT      NOT NULL DEFAULT 0,
  to_status   TINYINT      NOT NULL,
  operator    VARCHAR(32)  NOT NULL COMMENT 'buyer/seller/system/admin',
  remark      VARCHAR(255) NOT NULL DEFAULT '',
  created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_order (order_id, created_at)
) ENGINE=InnoDB COMMENT='订单状态日志';

-- ---------------------------------------------------------------------
-- 10. 支付单(微信电商收付通)
-- ---------------------------------------------------------------------
CREATE TABLE xj_pay_orders (
  id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  order_id       BIGINT UNSIGNED NOT NULL,
  out_trade_no   VARCHAR(32)  NOT NULL COMMENT '商户订单号',
  transaction_id VARCHAR(64)  NOT NULL DEFAULT '' COMMENT '微信支付单号',
  amount         DECIMAL(10,2) NOT NULL,
  status         TINYINT      NOT NULL DEFAULT 0 COMMENT '0待支付 1已支付 2已退款',
  split_status   TINYINT      NOT NULL DEFAULT 0 COMMENT '0未分账 1已分账 2分账失败',
  created_at     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  paid_at        DATETIME     NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_out_trade_no (out_trade_no),
  KEY idx_order (order_id)
) ENGINE=InnoDB COMMENT='支付单(微信电商收付通)';

-- ---------------------------------------------------------------------
-- 11. 分账流水
-- ---------------------------------------------------------------------
CREATE TABLE xj_split_results (
  id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  order_id        BIGINT UNSIGNED NOT NULL,
  pay_order_id    BIGINT UNSIGNED NOT NULL,
  receiver_type   TINYINT      NOT NULL COMMENT '1卖家 2平台(佣金)',
  receiver_id     BIGINT UNSIGNED NOT NULL COMMENT '卖家user_id或平台商户号ID',
  amount          DECIMAL(10,2) NOT NULL COMMENT '分账金额(卖家97%/平台3%)',
  status          TINYINT      NOT NULL DEFAULT 0 COMMENT '0待分账 1成功 2失败',
  wechat_split_no VARCHAR(64)  NOT NULL DEFAULT '' COMMENT '微信分账单号',
  created_at      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  done_at         DATETIME     NULL,
  PRIMARY KEY (id),
  KEY idx_order (order_id),
  KEY idx_status (status)
) ENGINE=InnoDB COMMENT='分账流水(资金由微信直接清算, 平台不过资金)';

-- ---------------------------------------------------------------------
-- 12. 退款单
-- ---------------------------------------------------------------------
CREATE TABLE xj_refunds (
  id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  order_id       BIGINT UNSIGNED NOT NULL,
  refund_no      VARCHAR(32)  NOT NULL,
  amount         DECIMAL(10,2) NOT NULL COMMENT '退款金额(全额原路退回, 佣金不计提)',
  reason         VARCHAR(255) NOT NULL DEFAULT '',
  evidence_url   VARCHAR(255) NOT NULL DEFAULT '' COMMENT '凭证图片',
  status         TINYINT      NOT NULL DEFAULT 0 COMMENT '0申请中 1卖家已同意 2卖家拒绝 3已退款 4仲裁中 5已撤销',
  refunded_at    DATETIME     NULL,
  created_at     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uk_refund_no (refund_no),
  KEY idx_order (order_id)
) ENGINE=InnoDB COMMENT='退款单';

-- ---------------------------------------------------------------------
-- 13. 佣金账单(结算)
-- ---------------------------------------------------------------------
CREATE TABLE xj_trade_bills (
  id               BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  order_id         BIGINT UNSIGNED NOT NULL,
  seller_id        BIGINT UNSIGNED NOT NULL,
  amount           DECIMAL(10,2) NOT NULL COMMENT '订单金额',
  commission_amount DECIMAL(10,2) NOT NULL COMMENT '平台佣金',
  seller_amount    DECIMAL(10,2) NOT NULL COMMENT '卖家应收(分账金额)',
  settle_status    TINYINT      NOT NULL DEFAULT 0 COMMENT '0未结算 1已结算(分账成功)',
  settle_cycle     VARCHAR(16)  NOT NULL DEFAULT 'T+1' COMMENT '结算周期',
  created_at       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  settled_at       DATETIME     NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_order (order_id),
  KEY idx_seller (seller_id, settle_status),
  KEY idx_cycle (created_at)
) ENGINE=InnoDB COMMENT='佣金账单(凌晨批处理生成)';

-- ---------------------------------------------------------------------
-- 14. 提现单
-- ---------------------------------------------------------------------
CREATE TABLE xj_withdraws (
  id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id      BIGINT UNSIGNED NOT NULL,
  withdraw_no  VARCHAR(32)  NOT NULL,
  amount       DECIMAL(10,2) NOT NULL,
  fee          DECIMAL(10,2) NOT NULL DEFAULT 0 COMMENT '提现手续费(费率可配置)',
  status       TINYINT      NOT NULL DEFAULT 0 COMMENT '0申请中 1打款中 2成功 3驳回',
  auditor_id   BIGINT UNSIGNED NOT NULL DEFAULT 0,
  audit_remark VARCHAR(255) NOT NULL DEFAULT '',
  created_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  done_at      DATETIME     NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_withdraw_no (withdraw_no),
  KEY idx_user (user_id, status)
) ENGINE=InnoDB COMMENT='提现单';

-- ---------------------------------------------------------------------
-- 15. 圈子表
-- ---------------------------------------------------------------------
CREATE TABLE xj_circles (
  id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  name         VARCHAR(64)  NOT NULL,
  type         TINYINT      NOT NULL COMMENT '1校内圈 2跨校圈 3兴趣圈',
  school_id    BIGINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '校内圈所属学校, 跨校/兴趣圈=0',
  owner_id     BIGINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '圈主user_id, 0=官方',
  icon_url     VARCHAR(255) NOT NULL DEFAULT '',
  intro        VARCHAR(255) NOT NULL DEFAULT '',
  level        INT          NOT NULL DEFAULT 1 COMMENT '圈子等级',
  member_count INT          NOT NULL DEFAULT 0 COMMENT '成员数(Redis计数异步落库)',
  status       TINYINT      NOT NULL DEFAULT 1,
  created_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_type (type, school_id)
) ENGINE=InnoDB COMMENT='圈子表';

-- ---------------------------------------------------------------------
-- 16. 圈子成员
-- ---------------------------------------------------------------------
CREATE TABLE xj_circle_members (
  id        BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  circle_id BIGINT UNSIGNED NOT NULL,
  user_id   BIGINT UNSIGNED NOT NULL,
  role      TINYINT      NOT NULL DEFAULT 0 COMMENT '0成员 1管理员 2圈主',
  joined_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uk_circle_user (circle_id, user_id),
  KEY idx_user (user_id)
) ENGINE=InnoDB COMMENT='圈子成员';

-- ---------------------------------------------------------------------
-- 17. 帖子表 [分库分表: school_id + 年月 月表]
-- ---------------------------------------------------------------------
CREATE TABLE xj_posts (
  id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  circle_id      BIGINT UNSIGNED NOT NULL,
  author_id      BIGINT UNSIGNED NOT NULL,
  school_id      BIGINT UNSIGNED NOT NULL COMMENT '分片键之一(校内圈; 跨校/兴趣圈=0, 按月表路由)',
  type           TINYINT      NOT NULL DEFAULT 1 COMMENT '1文字 2图文 3视频 4投票 5问答',
  title          VARCHAR(64)  NOT NULL DEFAULT '',
  content        TEXT         NOT NULL COMMENT '正文(进ES全文检索)',
  topic          VARCHAR(64)  NOT NULL DEFAULT '' COMMENT '话题标签',
  vote_options   VARCHAR(1024) NOT NULL DEFAULT '' COMMENT '投票选项JSON [{"text":"...","cnt":0}]',
  base_score     INT          NOT NULL DEFAULT 0 COMMENT '基础分(内容类型权重)',
  hot_score      DECIMAL(12,4) NOT NULL DEFAULT 0 COMMENT '热度分 = (base+赞*1+评*2+藏*3+转*4)*e^(-λt), λ=24h半衰期',
  exposure_count INT          NOT NULL DEFAULT 0 COMMENT '曝光数(新帖保底50-100, 配置可调)',
  like_count     INT          NOT NULL DEFAULT 0 COMMENT 'Redis计数异步落库',
  comment_count  INT          NOT NULL DEFAULT 0,
  collect_count  INT          NOT NULL DEFAULT 0,
  share_count    INT          NOT NULL DEFAULT 0,
  status         TINYINT      NOT NULL DEFAULT 0 COMMENT 'v1.1: 0待审 1正常(机审通过) 2下架 3删除',
  is_pin         TINYINT      NOT NULL DEFAULT 0 COMMENT '置顶',
  is_essence     TINYINT      NOT NULL DEFAULT 0 COMMENT '精华',
  created_at     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_circle (circle_id, status, created_at),
  KEY idx_school (school_id, created_at),
  KEY idx_hot (status, hot_score),
  KEY idx_author (author_id)
) ENGINE=InnoDB COMMENT='帖子表';

-- ---------------------------------------------------------------------
-- 18. 帖子评论(楼中楼)
-- ---------------------------------------------------------------------
CREATE TABLE xj_post_comments (
  id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  post_id       BIGINT UNSIGNED NOT NULL,
  parent_id     BIGINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '0=一级评论, 否则=楼中楼',
  reply_user_id BIGINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '被回复人',
  author_id     BIGINT UNSIGNED NOT NULL,
  content       VARCHAR(1000) NOT NULL,
  like_count    INT          NOT NULL DEFAULT 0,
  status        TINYINT      NOT NULL DEFAULT 1 COMMENT '1正常 2删除',
  created_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_post (post_id, parent_id, created_at)
) ENGINE=InnoDB COMMENT='帖子评论';

-- ---------------------------------------------------------------------
-- 19. 帖子互动(赞/藏/转)
-- ---------------------------------------------------------------------
CREATE TABLE xj_post_likes (
  id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  post_id    BIGINT UNSIGNED NOT NULL,
  comment_id BIGINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '0=帖子级互动',
  user_id    BIGINT UNSIGNED NOT NULL,
  act_type   TINYINT      NOT NULL COMMENT '1点赞 2收藏 3转发',
  created_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uk_post_user (post_id, comment_id, user_id, act_type),
  KEY idx_user (user_id, act_type)
) ENGINE=InnoDB COMMENT='帖子互动';

-- ---------------------------------------------------------------------
-- 20. 举报
-- ---------------------------------------------------------------------
CREATE TABLE xj_post_reports (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  target_type TINYINT      NOT NULL COMMENT '1帖子 2评论 3商品 4用户 5聊天',
  target_id   BIGINT UNSIGNED NOT NULL,
  reporter_id BIGINT UNSIGNED NOT NULL,
  reason      VARCHAR(255) NOT NULL DEFAULT '',
  status      TINYINT      NOT NULL DEFAULT 0 COMMENT '0待处理 1已处理 2驳回',
  handled_by  BIGINT UNSIGNED NOT NULL DEFAULT 0,
  created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_target (target_type, target_id),
  KEY idx_status (status)
) ENGINE=InnoDB COMMENT='举报';

-- ---------------------------------------------------------------------
-- 21. 短视频
-- ---------------------------------------------------------------------
CREATE TABLE xj_videos (
  id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  author_id  BIGINT UNSIGNED NOT NULL,
  goods_id   BIGINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '挂车商品ID',
  url        VARCHAR(255) NOT NULL COMMENT '视频 OSS URL',
  cover_url  VARCHAR(255) NOT NULL DEFAULT '',
  title      VARCHAR(64)  NOT NULL DEFAULT '',
  like_count INT          NOT NULL DEFAULT 0,
  status     TINYINT      NOT NULL DEFAULT 1 COMMENT '1正常 2下架',
  created_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_author (author_id),
  KEY idx_goods (goods_id)
) ENGINE=InnoDB COMMENT='短视频(集市Tab)';

-- ---------------------------------------------------------------------
-- 22. 会话表 [v1.1: user_a/user_b 可空, 修复群聊唯一键冲突]
-- ---------------------------------------------------------------------
CREATE TABLE xj_conversations (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  type        TINYINT      NOT NULL COMMENT '1单聊 2群聊',
  user_a      BIGINT UNSIGNED NULL DEFAULT NULL COMMENT '单聊双方(小id在前); 群聊置NULL(唯一键对NULL不去重)',
  user_b      BIGINT UNSIGNED NULL DEFAULT NULL COMMENT '单聊双方; 群聊置NULL',
  circle_id   BIGINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '群聊关联圈子',
  group_name  VARCHAR(64)  NOT NULL DEFAULT '',
  last_msg_id BIGINT UNSIGNED NOT NULL DEFAULT 0,
  updated_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uk_pair (user_a, user_b),
  KEY idx_circle (circle_id)
) ENGINE=InnoDB COMMENT='会话表';

-- ---------------------------------------------------------------------
-- 23. 消息表 [分库分表: conversation_id 哈希 64 表]
-- ---------------------------------------------------------------------
CREATE TABLE xj_messages (
  id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  conversation_id BIGINT UNSIGNED NOT NULL COMMENT '分片键',
  sender_id       BIGINT UNSIGNED NOT NULL,
  msg_type        TINYINT      NOT NULL COMMENT '1文本 2图片 3语音 4商品卡片 5引用 6系统',
  content         VARCHAR(2000) NOT NULL DEFAULT '',
  goods_id        BIGINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '商品卡片关联',
  quote_msg_id    BIGINT UNSIGNED NOT NULL DEFAULT 0,
  status          TINYINT      NOT NULL DEFAULT 1 COMMENT '1正常 2撤回 3删除',
  created_at      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_conv (conversation_id, id)
) ENGINE=InnoDB COMMENT='消息表';

-- ---------------------------------------------------------------------
-- 24. 小法庭案件
-- ---------------------------------------------------------------------
CREATE TABLE xj_cases (
  id               BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  case_no          VARCHAR(32)  NOT NULL,
  order_id         BIGINT UNSIGNED NOT NULL,
  title            VARCHAR(64)  NOT NULL COMMENT '脱敏后标题',
  content          TEXT         NOT NULL COMMENT '脱敏案情(隐藏双方身份)',
  evidence_urls    VARCHAR(1024) NOT NULL DEFAULT '' COMMENT '凭证图片, 逗号分隔',
  platform_verdict TINYINT      NOT NULL COMMENT '平台裁决 1支持买家 2支持卖家',
  verdict_reason   VARCHAR(500) NOT NULL DEFAULT '',
  stage            TINYINT      NOT NULL DEFAULT 1 COMMENT '1影子评议 2裁决模式',
  vote_status      TINYINT      NOT NULL DEFAULT 1 COMMENT '1投票中 2已截止',
  vote_buyer_cnt   INT          NOT NULL DEFAULT 0,
  vote_seller_cnt  INT          NOT NULL DEFAULT 0,
  vote_platform_cnt INT         NOT NULL DEFAULT 0,
  verdict_time     DATETIME     NULL COMMENT '平台裁决时间(执行后发布)',
  created_at       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uk_case_no (case_no),
  KEY idx_order (order_id),
  KEY idx_stage (stage, vote_status)
) ENGINE=InnoDB COMMENT='小法庭案件(影子评审: 平台裁决已执行, 发布供公众评议)';

-- ---------------------------------------------------------------------
-- 25. 小法庭投票(高信用全民参与)
-- ---------------------------------------------------------------------
CREATE TABLE xj_case_votes (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  case_id     BIGINT UNSIGNED NOT NULL,
  user_id     BIGINT UNSIGNED NOT NULL,
  vote_choice TINYINT      NOT NULL COMMENT '1支持买家 2支持卖家 3支持平台裁决',
  created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uk_case_user (case_id, user_id),
  KEY idx_user (user_id)
) ENGINE=InnoDB COMMENT='小法庭投票';

-- ---------------------------------------------------------------------
-- 26. 小法庭评论区(比例下方同步显示)
-- ---------------------------------------------------------------------
CREATE TABLE xj_case_comments (
  id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  case_id    BIGINT UNSIGNED NOT NULL,
  user_id    BIGINT UNSIGNED NOT NULL,
  parent_id  BIGINT UNSIGNED NOT NULL DEFAULT 0,
  content    VARCHAR(1000) NOT NULL,
  like_count INT          NOT NULL DEFAULT 0,
  status     TINYINT      NOT NULL DEFAULT 1,
  created_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_case (case_id, created_at)
) ENGINE=InnoDB COMMENT='小法庭评论区';

-- ---------------------------------------------------------------------
-- 27. 小法庭对比结果(用户裁决 vs 平台裁决)
-- ---------------------------------------------------------------------
CREATE TABLE xj_case_compare (
  id                BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  case_id           BIGINT UNSIGNED NOT NULL,
  week_no           VARCHAR(10)  NOT NULL COMMENT '周次 YYYYWW',
  platform_verdict  TINYINT      NOT NULL,
  vote_winner       TINYINT      NOT NULL COMMENT '1买家 2卖家 3平票/多数支持平台',
  vote_buyer_cnt    INT          NOT NULL DEFAULT 0,
  vote_seller_cnt   INT          NOT NULL DEFAULT 0,
  vote_platform_cnt INT          NOT NULL DEFAULT 0,
  is_consistent     TINYINT      NOT NULL DEFAULT 0 COMMENT '1用户多数与平台裁决一致',
  created_at        DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uk_case (case_id),
  KEY idx_week (week_no, is_consistent)
) ENGINE=InnoDB COMMENT='小法庭对比结果(一致率看板数据源)';

-- ---------------------------------------------------------------------
-- 28. 广告主
-- ---------------------------------------------------------------------
CREATE TABLE xj_advertisers (
  id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  name         VARCHAR(64)  NOT NULL,
  contact      VARCHAR(32)  NOT NULL DEFAULT '',
  phone        VARCHAR(20)  NOT NULL DEFAULT '',
  license_type TINYINT      NOT NULL DEFAULT 1 COMMENT '0个人 1个体户 2企业',
  license_no   VARCHAR(64)  NOT NULL DEFAULT '',
  balance      DECIMAL(10,2) NOT NULL DEFAULT 0 COMMENT '账户余额(预付)',
  status       TINYINT      NOT NULL DEFAULT 1 COMMENT '1正常 0停用',
  created_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_name (name)
) ENGINE=InnoDB COMMENT='广告主';

-- ---------------------------------------------------------------------
-- 29. 广告
-- ---------------------------------------------------------------------
CREATE TABLE xj_ads (
  id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  advertiser_id BIGINT UNSIGNED NOT NULL,
  title        VARCHAR(64)  NOT NULL,
  ad_type      TINYINT      NOT NULL COMMENT '1开屏 2信息流(第4/9位) 3详情横幅 4搜索位 5集市轮播 6圈子置顶',
  image_url    VARCHAR(255) NOT NULL DEFAULT '',
  link_url     VARCHAR(255) NOT NULL DEFAULT '',
  bid_type     TINYINT      NOT NULL DEFAULT 2 COMMENT '1CPM 2CPC',
  bid_price    DECIMAL(10,2) NOT NULL COMMENT '出价(元/千次曝光 或 元/点击)',
  daily_freq   INT          NOT NULL DEFAULT 3 COMMENT '频控: 同用户同广告每日曝光上限',
  status       TINYINT      NOT NULL DEFAULT 1 COMMENT '1投放中 0暂停',
  source       TINYINT      NOT NULL DEFAULT 1 COMMENT '1广告主提交后台审核 2线下约谈后台直发',
  created_by   BIGINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '后台直发人',
  created_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_type (ad_type, status)
) ENGINE=InnoDB COMMENT='广告位(行业黑名单词库: 校园贷/医美/游戏代练/刷单等禁投, 仅作审核参考)';

-- ---------------------------------------------------------------------
-- 30. 广告投放计划
-- ---------------------------------------------------------------------
CREATE TABLE xj_ad_plans (
  id        BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  ad_id     BIGINT UNSIGNED NOT NULL,
  start_at  DATETIME     NOT NULL,
  end_at    DATETIME     NOT NULL,
  budget    DECIMAL(10,2) NOT NULL COMMENT '预算上限',
  spent     DECIMAL(10,2) NOT NULL DEFAULT 0 COMMENT '已消耗',
  status    TINYINT      NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  KEY idx_ad (ad_id, status)
) ENGINE=InnoDB COMMENT='广告投放计划';

-- ---------------------------------------------------------------------
-- 31. 广告扣费流水 [分库分表: 年月 月表]
-- ---------------------------------------------------------------------
CREATE TABLE xj_ad_bills (
  id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  plan_id    BIGINT UNSIGNED NOT NULL,
  ad_id      BIGINT UNSIGNED NOT NULL,
  user_id    BIGINT UNSIGNED NOT NULL COMMENT '曝光/点击用户',
  bill_type  TINYINT      NOT NULL COMMENT '1曝光 2点击',
  amount     DECIMAL(10,2) NOT NULL COMMENT '扣费(CPM按千次摊, CPC按次)',
  created_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_plan (plan_id, created_at),
  KEY idx_user_ad (user_id, ad_id, created_at)
) ENGINE=InnoDB COMMENT='广告扣费流水';

-- ---------------------------------------------------------------------
-- 32. 薯条自助推广订单
-- ---------------------------------------------------------------------
CREATE TABLE xj_promo_orders (
  id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id       BIGINT UNSIGNED NOT NULL,
  target_type   TINYINT      NOT NULL COMMENT '1商品 2帖子',
  target_id     BIGINT UNSIGNED NOT NULL,
  exposure_cnt  INT          NOT NULL COMMENT '购买曝光量 500/1000/3000/5000',
  cpm_price     DECIMAL(10,2) NOT NULL COMMENT 'CPM单价(配置中心可调)',
  amount        DECIMAL(10,2) NOT NULL,
  delivered_cnt INT          NOT NULL DEFAULT 0 COMMENT '已投曝光',
  status        TINYINT      NOT NULL DEFAULT 0 COMMENT '0待支付 1投放中 2完成',
  created_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_user (user_id, status)
) ENGINE=InnoDB COMMENT='薯条自助推广订单';

-- ---------------------------------------------------------------------
-- 33. 达人接单任务(蒲公英模式)
-- ---------------------------------------------------------------------
CREATE TABLE xj_koc_tasks (
  id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  advertiser_id  BIGINT UNSIGNED NOT NULL,
  title          VARCHAR(64)  NOT NULL,
  requirement    VARCHAR(1000) NOT NULL DEFAULT '',
  reward         DECIMAL(10,2) NOT NULL COMMENT '任务报酬',
  commission_rate DECIMAL(5,2) NOT NULL DEFAULT 15.00 COMMENT '平台抽成(默认15%, 可配置)',
  status         TINYINT      NOT NULL DEFAULT 1 COMMENT '1招募中 2进行中 3完成 4关闭',
  deadline       DATETIME     NULL,
  created_at     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id)
) ENGINE=InnoDB COMMENT='达人接单任务';

-- ---------------------------------------------------------------------
-- 34. 达人接单记录
-- ---------------------------------------------------------------------
CREATE TABLE xj_koc_take (
  id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  task_id       BIGINT UNSIGNED NOT NULL,
  user_id       BIGINT UNSIGNED NOT NULL,
  content_url   VARCHAR(255) NOT NULL DEFAULT '' COMMENT '产出内容链接',
  status        TINYINT      NOT NULL DEFAULT 0 COMMENT '0已接单 1已提交 2已结算',
  settle_amount DECIMAL(10,2) NOT NULL DEFAULT 0 COMMENT '达人实际到手(扣平台抽成后)',
  created_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uk_task_user (task_id, user_id)
) ENGINE=InnoDB COMMENT='达人接单记录';

-- ---------------------------------------------------------------------
-- 35. 客服工单(三通道)
-- ---------------------------------------------------------------------
CREATE TABLE xj_work_orders (
  id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  order_no     VARCHAR(32)  NOT NULL,
  wtype        TINYINT      NOT NULL COMMENT '1交易纠纷 2举报 3认证申诉',
  biz_id       BIGINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '关联订单/举报/认证记录ID',
  applicant_id BIGINT UNSIGNED NOT NULL,
  content      VARCHAR(2000) NOT NULL DEFAULT '',
  evidence_urls VARCHAR(1024) NOT NULL DEFAULT '',
  status       TINYINT      NOT NULL DEFAULT 0 COMMENT '0待处理 1处理中 2已解决 3关闭',
  handler_id   BIGINT UNSIGNED NOT NULL DEFAULT 0,
  sla_deadline DATETIME     NOT NULL COMMENT '48小时SLA截止时间',
  created_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  solved_at    DATETIME     NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_order_no (order_no),
  KEY idx_status (status, sla_deadline),
  KEY idx_applicant (applicant_id)
) ENGINE=InnoDB COMMENT='客服工单(48h SLA)';

-- ---------------------------------------------------------------------
-- 36. 审核队列
-- ---------------------------------------------------------------------
CREATE TABLE xj_audit_queue (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  biz_type    TINYINT      NOT NULL COMMENT '1商品 2帖子 3评论 4广告 5认证',
  biz_id      BIGINT UNSIGNED NOT NULL,
  submitter_id BIGINT UNSIGNED NOT NULL DEFAULT 0,
  status      TINYINT      NOT NULL DEFAULT 0 COMMENT '0待审 1通过 2驳回',
  auditor_id  BIGINT UNSIGNED NOT NULL DEFAULT 0,
  remark      VARCHAR(255) NOT NULL DEFAULT '',
  created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  audited_at  DATETIME     NULL,
  PRIMARY KEY (id),
  KEY idx_biz (biz_type, status, created_at)
) ENGINE=InnoDB COMMENT='审核队列';

-- ---------------------------------------------------------------------
-- 37. 平台配置中心(所有费率/规则参数化, 超管自配置)
-- ---------------------------------------------------------------------
CREATE TABLE xj_platform_config (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  config_key  VARCHAR(64)  NOT NULL,
  config_value VARCHAR(255) NOT NULL,
  description VARCHAR(255) NOT NULL DEFAULT '',
  updated_by  BIGINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '修改人(后台用户ID)',
  updated_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uk_key (config_key)
) ENGINE=InnoDB COMMENT='平台配置中心';

-- ---------------------------------------------------------------------
-- 38. 配置修改审计日志
-- ---------------------------------------------------------------------
CREATE TABLE xj_config_audit_log (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  config_key  VARCHAR(64)  NOT NULL,
  old_value   VARCHAR(255) NOT NULL DEFAULT '',
  new_value   VARCHAR(255) NOT NULL,
  operator_id BIGINT UNSIGNED NOT NULL COMMENT '后台用户ID',
  created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_key (config_key, created_at)
) ENGINE=InnoDB COMMENT='配置修改审计日志(谁改的/改前/改后/何时)';

-- ---------------------------------------------------------------------
-- 39. 站内通知/订阅消息
-- ---------------------------------------------------------------------
CREATE TABLE xj_notifications (
  id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id    BIGINT UNSIGNED NOT NULL,
  ntype      TINYINT      NOT NULL DEFAULT 1 COMMENT '1站内信 2订阅消息',
  title      VARCHAR(64)  NOT NULL DEFAULT '',
  content    VARCHAR(500) NOT NULL DEFAULT '',
  link       VARCHAR(255) NOT NULL DEFAULT '',
  is_read    TINYINT      NOT NULL DEFAULT 0,
  created_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_user (user_id, is_read, created_at)
) ENGINE=InnoDB COMMENT='通知';

-- ---------------------------------------------------------------------
-- 40. 校园大使
-- ---------------------------------------------------------------------
CREATE TABLE xj_school_ambassadors (
  id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  school_id       BIGINT UNSIGNED NOT NULL,
  user_id         BIGINT UNSIGNED NOT NULL,
  commission_rate DECIMAL(5,2) NOT NULL DEFAULT 0 COMMENT '地推/活动分成(配置可调)',
  status          TINYINT      NOT NULL DEFAULT 1,
  joined_at       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uk_school (school_id),
  KEY idx_user (user_id)
) ENGINE=InnoDB COMMENT='校园大使(每校1名)';

-- ---------------------------------------------------------------------
-- 41. 后台用户(RBAC)
-- ---------------------------------------------------------------------
CREATE TABLE xj_admin_users (
  id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  username     VARCHAR(32)  NOT NULL,
  password_hash VARCHAR(128) NOT NULL,
  real_name    VARCHAR(32)  NOT NULL DEFAULT '',
  role         TINYINT      NOT NULL COMMENT '1超级管理员(含费率配置) 2运营 3内容审核 4客服 5财务 6校园大使',
  status       TINYINT      NOT NULL DEFAULT 1,
  created_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uk_username (username)
) ENGINE=InnoDB COMMENT='后台用户(RBAC)';

-- ---------------------------------------------------------------------
-- 42. 后台操作日志
-- ---------------------------------------------------------------------
CREATE TABLE xj_admin_logs (
  id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  admin_id   BIGINT UNSIGNED NOT NULL,
  action     VARCHAR(64)  NOT NULL,
  target     VARCHAR(128) NOT NULL DEFAULT '',
  detail     VARCHAR(1000) NOT NULL DEFAULT '',
  created_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_admin (admin_id, created_at)
) ENGINE=InnoDB COMMENT='后台操作日志(全留痕)';

-- =====================================================================
-- 默认配置数据(平台配置中心, 超管可改; 历史订单按成交时费率快照冻结)
-- =====================================================================
INSERT INTO xj_platform_config (config_key, config_value, description) VALUES
('commission_rate_default',  '3',     '担保交易默认佣金率(%)'),
('commission_rate_book',     '1',     '教材类佣金率(%)'),
('withdraw_fee',             '0.1',   '提现手续费(%)'),
('commission_free_switch',   '0',     '免佣活动开关(0关 1开, 运营日历季开启)'),
('publish_require_auth',     '1',     'v1.1新增: 发布商品需校园认证(1开); 信用分门槛需与此项同时校验'),
('ad_cpm_floor',             '5',     '广告CPM底价(元/千次曝光)'),
('ad_cpc_floor',             '0.3',   '广告CPC底价(元/点击)'),
('promo_cpm_price',          '10',    '薯条推广CPM单价(元/千次曝光)'),
('koc_commission_rate',      '15',    '达人接单平台抽成(%)'),
('credit_add_trade',         '50',    '交易履约加分/单'),
('credit_sub_complaint',     '30',    '被投诉扣分/次'),
('credit_sub_verdict_lose',  '50',    '仲裁判负扣分/次'),
('credit_min_trade',         '40',    '担保交易信用分门槛'),
('credit_min_publish',       '40',    '发布商品信用分门槛(需同时满足publish_require_auth)'),
('order_pay_expire_hours',   '24',    '待付款超时关单(小时)'),
('auto_confirm_days',        '10',    '快递发货自动确认收货(天)'),
('auto_confirm_face_hours',  '24',    '面交核销后自动确认(小时)'),
('verify_code_refresh_sec',  '600',   'v1.1新增: 面交核销码刷新周期(秒)'),
('refund_seller_handle_hours','48',   '退款申请卖家处理时限(小时), 超时转仲裁'),
('post_base_exposure_min',   '50',    '新帖保底曝光下限(次)'),
('post_base_exposure_max',   '100',   '新帖保底曝光上限(次)'),
('case_vote_credit_min',     '0',     '小法庭投票信用分门槛(初期0=认证学生即可投)'),
('case_vote_weight_credit',  '1.5',   '高信用票权倍数(可选, 1=不启用)'),
('case_switch_weeks',        '4',     '小法庭切换评估周期(连续N周)'),
('case_switch_rate',         '80',    '小法庭切换一致率阈值(%)'),
('case_switch_samples',      '100',   '小法庭切换最少评议样本数(件)'),
('ad_daily_freq',            '3',     '同用户同广告每日曝光上限');

-- 学校示例数据
INSERT INTO xj_schools (name, city, alias) VALUES
('楚雄师范学院', '楚雄', '楚雄师院'),
('云南大学', '昆明', '云大'),
('昆明理工大学', '昆明', '昆工'),
('云南师范大学', '昆明', '云师大'),
('大理大学', '大理', '大理大学');

-- 后台初始账号(仅部署时执行, 密码hash需用业务侧BCrypt生成, 此处占位)
-- INSERT INTO xj_admin_users (username, password_hash, real_name, role) VALUES ('admin', '<BCRYPT_HASH>', '超级管理员', 1);
