# V2Board Docker 部署

使用 Docker Compose 一键部署 V2Board，包含 Nginx + PHP-FPM + MySQL + Redis 完整运行环境。

## 目录结构

```
v2board/
├── Dockerfile                    # PHP 8.1 FPM 镜像定义
├── docker-compose.yml            # 服务编排 (nginx + php + mysql + redis)
├── .env.docker.example           # 环境变量模板
├── .dockerignore
└── docker/
    ├── entrypoint.sh             # 容器初始化脚本 (非交互式安装)
    ├── nginx/
    │   └── v2board.conf          # Nginx 虚拟主机配置
    ├── supervisor/
    │   ├── supervisord.conf      # Supervisor 主配置
    │   └── conf.d/
    │       └── app.conf          # PHP-FPM + Horizon + Cron 进程配置
    └── cron/
        └── v2board               # 定时任务 (每分钟执行 Laravel 调度器)
```

## 架构说明

| 容器 | 镜像 | 说明 |
|------|------|------|
| `v2board-nginx` | nginx:1.25-alpine | Web 服务器，反代 PHP-FPM |
| `v2board-php` | 本地构建 (PHP 8.1 FPM Alpine) | PHP-FPM + Supervisor 管理 Horizon 队列 + Cron 调度器 |
| `v2board-mysql` | mysql:8.0 | 数据库，UTF8MB4 |
| `v2board-redis` | redis:7-alpine | 缓存 / 队列 / Session |

**PHP 容器内 Supervisor 管理的进程：**
- `php-fpm` — 处理 PHP 请求 (监听 9000 端口)
- `horizon` — Laravel Horizon 队列工作器
- `cron` — 每分钟执行 `php artisan schedule:run`

## 快速开始

### 1. 配置环境变量

```bash
cd v2board
cp .env.docker.example .env.docker
```

编辑 `.env.docker`，修改以下关键配置：

```ini
# Web 访问端口
NGINX_PORT=8080

# MySQL 密码（务必修改默认值）
MYSQL_ROOT_PASSWORD=<your_root_password>
DB_PASSWORD=<your_db_password>

# 管理员账号
ADMIN_EMAIL=admin@v2board.com
ADMIN_PASSWORD=        # 留空则自动生成随机密码

# 站点 URL
APP_URL=http://localhost:8080
```

### 2. 构建并启动

```bash
docker compose --env-file .env.docker up -d --build
```

### 3. 查看管理员凭据

首次启动时，entrypoint 会自动完成以下操作：
- 安装 Composer 依赖
- 生成 `.env` 配置文件和 APP_KEY
- 导入数据库结构 (install.sql)
- 创建管理员账号

管理员密码会在 PHP 容器日志中输出：

```bash
docker compose logs php | grep -A5 "Admin"
```

输出示例：
```
================================================
  Admin Email:    admin@v2board.com
  Admin Password: a1b2c3d4e5f6
================================================
```

### 4. 访问

- 前台：http://localhost:8080
- 后台管理面板：http://localhost:8080/`<secure_path>`

> `<secure_path>` 是基于 APP_KEY 生成的哈希路径，可在管理面板的「网站设置」中查看或修改。

## 常用命令

```bash
# 启动
docker compose --env-file .env.docker up -d

# 停止
docker compose down

# 查看日志
docker compose logs -f php
docker compose logs -f nginx

# 进入 PHP 容器
docker compose exec php bash

# 重新构建（修改代码后）
docker compose --env-file .env.docker up -d --build

# 完全重置（删除所有数据）
docker compose down -v
docker compose --env-file .env.docker up -d --build
```

## 更新 V2Board

```bash
# 1. 拉取最新代码
git pull origin master

# 2. 重新构建并启动
docker compose --env-file .env.docker up -d --build

# 3. 执行更新命令（导入 update.sql）
docker compose exec php php artisan v2board:update
```

## 数据持久化

| 卷名 | 容器路径 | 说明 |
|------|----------|------|
| `app_data` | /var/www/html | 应用代码（含 vendor） |
| `mysql_data` | /var/lib/mysql | MySQL 数据 |
| `redis_data` | /data | Redis AOF 持久化 |

> **注意**：`app_data` 是命名卷，首次启动后从镜像填充。如果修改了代码并重新构建，需要先 `docker compose down -v` 删除旧卷，或手动 `docker compose exec php` 进入容器同步文件。

## 自定义 PHP 配置

如需调整 PHP 配置（内存限制、上传大小等），可在 `docker/` 目录下添加 `php.ini`，并在 Dockerfile 中添加：

```dockerfile
COPY docker/php.ini /usr/local/etc/php/conf.d/v2board.ini
```

## 自定义 Nginx 配置

修改 `docker/nginx/v2board.conf` 后重启 Nginx 容器即可：

```bash
docker compose restart nginx
```

## 故障排查

### 数据库连接失败
```bash
docker compose exec php php artisan tinker
>>> DB::connection()->getPdo();
```

### Horizon 队列不工作
```bash
docker compose exec php php artisan horizon:status
docker compose exec php php artisan horizon:terminate  # 重启
```

### 权限问题
```bash
docker compose exec php chown -R www-data:www-data storage bootstrap/cache
docker compose exec php chmod -R 777 storage bootstrap/cache
```

### 重置安装
```bash
docker compose exec php rm -f .env
docker compose restart php
```
