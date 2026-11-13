/*
 * h700-sysinfo: full-screen system information for dArkOS on the RG35XX-H.
 * Replaces the console report of /opt/system/System Info.sh.
 *
 *   h700-sysinfo              show until any button or key is pressed
 *   h700-sysinfo --shot F     render one frame to BMP file F and exit
 */
#include <SDL2/SDL.h>
#include <SDL2/SDL_ttf.h>
#include <ifaddrs.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>

#define FONT_BOLD "/usr/bin/emulationstation/resources/OpenSans-CondBold.ttf"
#define FONT_TEXT "/usr/share/fonts/truetype/dejavu/DejaVuSansCondensed.ttf"
#define FONT_TEXT_ALT "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"

static const SDL_Color BG = {18, 20, 24, 255};
static const SDL_Color CARD = {30, 34, 40, 255};
static const SDL_Color EDGE = {44, 49, 58, 255};
static const SDL_Color TITLE = {240, 176, 64, 255};
static const SDL_Color LABEL = {140, 148, 160, 255};
static const SDL_Color VALUE = {232, 234, 238, 255};
static const SDL_Color BAR_BG = {50, 55, 64, 255};
static const SDL_Color GOOD = {92, 184, 112, 255};
static const SDL_Color WARN = {232, 168, 56, 255};
static const SDL_Color BAD = {220, 84, 72, 255};

static SDL_Renderer *R;
static TTF_Font *f_head, *f_title, *f_label, *f_value;
static int W, H, PAD, LINE;

/* ---------- data ---------- */

static int read_str(const char *path, char *buf, size_t n)
{
	FILE *f = fopen(path, "r");
	if (!f)
		return 0;
	size_t r = fread(buf, 1, n - 1, f);
	fclose(f);
	buf[r] = 0;
	while (r && (buf[r - 1] == '\n' || buf[r - 1] == ' '))
		buf[--r] = 0;
	return r > 0;
}

static long read_long(const char *path, long def)
{
	char b[64];
	return read_str(path, b, sizeof b) ? strtol(b, NULL, 10) : def;
}

static int run(const char *cmd, char *buf, size_t n)
{
	FILE *p = popen(cmd, "r");
	if (!p)
		return 0;
	size_t r = fread(buf, 1, n - 1, p);
	pclose(p);
	buf[r] = 0;
	while (r && (buf[r - 1] == '\n' || buf[r - 1] == ' '))
		buf[--r] = 0;
	return r > 0;
}

/* temperature in C of the first thermal zone whose type is t, or -1000 */
static int zone_temp(const char *t)
{
	char path[128], type[64];
	for (int i = 0; i < 16; i++) {
		snprintf(path, sizeof path, "/sys/class/thermal/thermal_zone%d/type", i);
		if (!read_str(path, type, sizeof type))
			break;
		if (strcmp(type, t) == 0) {
			snprintf(path, sizeof path, "/sys/class/thermal/thermal_zone%d/temp", i);
			return (int)(read_long(path, -1000000) / 1000);
		}
	}
	return -1000;
}

static void soc_name(char *buf, size_t n)
{
	char c[256];
	FILE *f = fopen("/proc/device-tree/compatible", "r");
	size_t r = f ? fread(c, 1, sizeof c - 1, f) : 0;
	if (f)
		fclose(f);
	c[r] = 0;
	/* strings are NUL separated; the last one is the SoC, "vendor,chip" */
	const char *last = c;
	for (size_t i = 0; i + 1 < r; i++)
		if (c[i] == 0)
			last = c + i + 1;
	const char *chip = strchr(last, ',');
	chip = chip ? chip + 1 : last;
	const char *dash = strrchr(chip, '-');
	snprintf(buf, n, "%s", dash ? dash + 1 : chip);
	for (char *p = buf; *p; p++)
		if (*p >= 'a' && *p <= 'z')
			*p -= 32;
	if (strncmp(last, "allwinner", 9) == 0) {
		char t[64];
		snprintf(t, sizeof t, "Allwinner %s", buf);
		snprintf(buf, n, "%s", t);
	}
}

static int ipv4(const char *ifname, char *buf, size_t n)
{
	struct ifaddrs *ifa, *i;
	int ok = 0;
	if (getifaddrs(&ifa))
		return 0;
	for (i = ifa; i; i = i->ifa_next)
		if (i->ifa_addr && i->ifa_addr->sa_family == AF_INET && strcmp(i->ifa_name, ifname) == 0) {
			inet_ntop(AF_INET, &((struct sockaddr_in *)i->ifa_addr)->sin_addr, buf, n);
			ok = 1;
			break;
		}
	freeifaddrs(ifa);
	return ok;
}

static void human(double bytes, char *buf, size_t n)
{
	const char *u[] = {"B", "KB", "MB", "GB", "TB"};
	int i = 0;
	while (bytes >= 1024 && i < 4) {
		bytes /= 1024;
		i++;
	}
	snprintf(buf, n, i >= 3 ? "%.1f %s" : "%.0f %s", bytes, u[i]);
}

/* ---------- drawing ---------- */

static void color(SDL_Color c) { SDL_SetRenderDrawColor(R, c.r, c.g, c.b, c.a); }

static void fill(int x, int y, int w, int h, SDL_Color c)
{
	SDL_Rect r = {x, y, w, h};
	color(c);
	SDL_RenderFillRect(R, &r);
}

/* draw text; align 0 left, 1 right (x is the right edge); returns width */
static int text(TTF_Font *f, SDL_Color c, int x, int y, int align, const char *fmt, ...)
{
	char s[256];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(s, sizeof s, fmt, ap);
	va_end(ap);
	if (!*s)
		return 0;
	SDL_Surface *sf = TTF_RenderUTF8_Blended(f, s, c);
	if (!sf)
		return 0;
	SDL_Texture *t = SDL_CreateTextureFromSurface(R, sf);
	SDL_Rect d = {align ? x - sf->w : x, y, sf->w, sf->h};
	SDL_RenderCopy(R, t, NULL, &d);
	int w = sf->w;
	SDL_DestroyTexture(t);
	SDL_FreeSurface(sf);
	return w;
}

typedef struct {
	int x, y, w, h, cy;
} Card;

static Card card(int x, int y, int w, int h, const char *title)
{
	fill(x, y, w, h, EDGE);
	fill(x + 1, y + 1, w - 2, h - 2, CARD);
	fill(x + 1, y + 1, 3, h - 2, TITLE);
	text(f_title, TITLE, x + PAD + 2, y + PAD / 2, 0, "%s", title);
	Card c = {x, y, w, h, y + PAD / 2 + TTF_FontLineSkip(f_title)};
	return c;
}

static void row(Card *c, const char *label, SDL_Color vc, const char *fmt, ...)
{
	char s[256];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(s, sizeof s, fmt, ap);
	va_end(ap);
	text(f_label, LABEL, c->x + PAD + 2, c->cy, 0, "%s", label);
	text(f_value, vc, c->x + c->w - PAD, c->cy, 1, "%s", s);
	c->cy += LINE;
}

static SDL_Color level(int pct, int high_is_bad)
{
	if (high_is_bad)
		return pct >= 90 ? BAD : pct >= 75 ? WARN : GOOD;
	return pct <= 15 ? BAD : pct <= 30 ? WARN : GOOD;
}

/* label, right-aligned detail, then a bar on the next line */
static void bar(Card *c, const char *label, const char *detail, int pct, SDL_Color fg)
{
	if (pct < 0)
		pct = 0;
	if (pct > 100)
		pct = 100;
	text(f_label, LABEL, c->x + PAD + 2, c->cy, 0, "%s", label);
	text(f_value, VALUE, c->x + c->w - PAD, c->cy, 1, "%s", detail);
	c->cy += LINE;
	int bx = c->x + PAD + 2, bw = c->w - 2 * PAD - 2, bh = LINE / 3;
	fill(bx, c->cy, bw, bh, BAR_BG);
	fill(bx, c->cy, bw * pct / 100, bh, fg);
	c->cy += bh + LINE / 3;
}

static void disk(Card *c, const char *path, const char *name)
{
	struct statvfs v;
	struct stat a, b;
	if (statvfs(path, &v) || v.f_blocks == 0)
		return;
	/* a mount point only: skip directories that live on the parent fs */
	if (strcmp(path, "/") != 0 && (stat(path, &a) || stat("/", &b) || a.st_dev == b.st_dev))
		return;
	double total = (double)v.f_blocks * v.f_frsize, avail = (double)v.f_bavail * v.f_frsize;
	double used = total - (double)v.f_bfree * v.f_frsize;
	char t[32], f[32], d[80];
	human(total, t, sizeof t);
	human(avail, f, sizeof f);
	int pct = total > 0 ? (int)(used * 100 / total) : 0;
	snprintf(d, sizeof d, "%s free of %s", f, t);
	bar(c, name, d, pct, level(pct, 1));
}

static void draw(void)
{
	char a[256], b[128];
	color(BG);
	SDL_RenderClear(R);

	/* header */
	int hh = TTF_FontLineSkip(f_head) + PAD / 2;
	fill(0, 0, W, hh, CARD);
	fill(0, hh, W, 2, TITLE);
	text(f_head, VALUE, PAD, PAD / 4, 0, "System Info");
	time_t now = time(NULL);
	strftime(a, sizeof a, "%a %d %b  %H:%M:%S", localtime(&now));
	text(f_label, LABEL, W - PAD, (hh - TTF_FontLineSkip(f_label)) / 2, 1, "%s", a);

	int top = hh + PAD, colw = (W - 3 * PAD) / 2, lx = PAD, rx = 2 * PAD + colw;
	int title = PAD / 2 + TTF_FontLineSkip(f_title) + PAD / 2;

	/* left column: system, CPU, network */
	struct utsname u;
	uname(&u);
	Card c = card(lx, top, colw, title + 4 * LINE, "SYSTEM");
	if (!read_str("/proc/device-tree/model", a, sizeof a))
		snprintf(a, sizeof a, "%s", u.nodename);
	row(&c, "Device", VALUE, "%s", a);
	row(&c, "Kernel", VALUE, "%s", u.release);
	run("uptime -p | sed 's/^up //'", a, sizeof a);
	row(&c, "Uptime", VALUE, "%s", a);
	read_str("/proc/loadavg", a, sizeof a);
	a[14] = 0;
	row(&c, "Load", VALUE, "%s", a);

	int y = c.y + c.h + PAD;
	c = card(lx, y, colw, title + 4 * LINE, "CPU");
	soc_name(b, sizeof b);
	row(&c, "Chip", VALUE, "%s, %ld cores", b, sysconf(_SC_NPROCESSORS_ONLN));
	long khz = read_long("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq", 0);
	read_str("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor", a, sizeof a);
	row(&c, "Clock", VALUE, khz ? "%ld MHz  %s" : "unknown", khz / 1000, a);
	int ct = zone_temp("cpu-thermal"), gt = zone_temp("gpu-thermal");
	row(&c, "CPU temp", ct > -1000 ? level(ct, 1) : LABEL, ct > -1000 ? "%d °C" : "n/a", ct);
	row(&c, "GPU temp", gt > -1000 ? level(gt, 1) : LABEL, gt > -1000 ? "%d °C" : "n/a", gt);

	y = c.y + c.h + PAD;
	c = card(lx, y, colw, H - y - PAD - LINE, "NETWORK");
	read_str("/sys/class/net/wlan0/operstate", a, sizeof a);
	int up = strcmp(a, "up") == 0;
	row(&c, "Wi-Fi", up ? GOOD : LABEL, "%s", up ? "connected" : a[0] ? a : "absent");
	if (up && run("iw dev wlan0 link | sed -n 's/^\\s*SSID: //p'", b, sizeof b))
		row(&c, "SSID", VALUE, "%s", b);
	if (ipv4("wlan0", b, sizeof b))
		row(&c, "Address", VALUE, "%s", b);

	/* right column: battery, memory, storage */
	const char *B = "/sys/class/power_supply/battery";
	char p[128];
	c = card(rx, top, colw, title + 4 * LINE + LINE / 2, "BATTERY");
	snprintf(p, sizeof p, "%s/capacity", B);
	int cap = (int)read_long(p, -1);
	snprintf(p, sizeof p, "%s/status", B);
	if (!read_str(p, b, sizeof b))
		snprintf(b, sizeof b, "unknown");
	snprintf(a, sizeof a, "%d%%  %s", cap, b);
	bar(&c, "Charge", a, cap, strcmp(b, "Charging") == 0 ? GOOD : level(cap, 0));
	snprintf(p, sizeof p, "%s/voltage_now", B);
	row(&c, "Voltage", VALUE, "%.2f V", read_long(p, 0) / 1e6);
	snprintf(p, sizeof p, "%s/current_now", B);
	row(&c, "Current", VALUE, "%+.2f A", read_long(p, 0) / 1e6);

	y = c.y + c.h + PAD;
	c = card(rx, y, colw, title + 4 * LINE + 2 * (LINE / 3 + LINE / 3), "MEMORY");
	long mt = 0, ma = 0, st = 0, sf = 0;
	FILE *m = fopen("/proc/meminfo", "r");
	while (m && fgets(a, sizeof a, m)) {
		sscanf(a, "MemTotal: %ld", &mt);
		sscanf(a, "MemAvailable: %ld", &ma);
		sscanf(a, "SwapTotal: %ld", &st);
		sscanf(a, "SwapFree: %ld", &sf);
	}
	if (m)
		fclose(m);
	char t1[32], t2[32];
	human((mt - ma) * 1024.0, t1, sizeof t1);
	human(mt * 1024.0, t2, sizeof t2);
	snprintf(a, sizeof a, "%s of %s", t1, t2);
	int mp = mt ? (int)((mt - ma) * 100 / mt) : 0;
	bar(&c, "RAM", a, mp, level(mp, 1));
	if (st) {
		human((st - sf) * 1024.0, t1, sizeof t1);
		human(st * 1024.0, t2, sizeof t2);
		snprintf(a, sizeof a, "%s of %s", t1, t2);
		int sp = (int)((st - sf) * 100 / st);
		bar(&c, "Swap", a, sp, level(sp, 1));
	} else {
		row(&c, "Swap", LABEL, "none");
	}

	y = c.y + c.h + PAD;
	c = card(rx, y, colw, H - y - PAD - LINE, "STORAGE");
	disk(&c, "/", "System");
	disk(&c, "/roms", "ROMs");
	disk(&c, "/roms2", "ROMs 2");

	/* footer */
	text(f_label, LABEL, W - PAD, H - LINE, 1, "Any button to close");
}

static TTF_Font *font(const char *path, const char *alt, int px)
{
	TTF_Font *f = TTF_OpenFont(path, px);
	if (!f && alt)
		f = TTF_OpenFont(alt, px);
	if (!f) {
		fprintf(stderr, "font %s: %s\n", path, TTF_GetError());
		exit(1);
	}
	return f;
}

static void fonts(void)
{
	PAD = H / 48 > 6 ? H / 48 : 6;
	f_head = font(FONT_BOLD, FONT_TEXT_ALT, H / 16);
	f_title = font(FONT_BOLD, FONT_TEXT_ALT, H / 26);
	f_label = font(FONT_TEXT, FONT_TEXT_ALT, H / 30);
	f_value = font(FONT_TEXT, FONT_TEXT_ALT, H / 30);
	LINE = TTF_FontLineSkip(f_value) + 1;
}

int main(int argc, char **argv)
{
	const char *shot = argc == 3 && strcmp(argv[1], "--shot") == 0 ? argv[2] : NULL;

	if (shot) {
		W = 640;
		H = 480;
		SDL_Surface *s = SDL_CreateRGBSurfaceWithFormat(0, W, H, 32, SDL_PIXELFORMAT_ARGB8888);
		R = SDL_CreateSoftwareRenderer(s);
		TTF_Init();
		fonts();
		draw();
		SDL_RenderPresent(R);
		return SDL_SaveBMP(s, shot) ? 1 : 0;
	}

	if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_JOYSTICK | SDL_INIT_GAMECONTROLLER)) {
		fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
		return 1;
	}
	SDL_DisplayMode dm;
	SDL_GetCurrentDisplayMode(0, &dm);
	W = dm.w;
	H = dm.h;
	SDL_Window *win = SDL_CreateWindow("System Info", 0, 0, W, H, SDL_WINDOW_FULLSCREEN);
	R = SDL_CreateRenderer(win, -1, SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
	if (!R)
		R = SDL_CreateRenderer(win, -1, SDL_RENDERER_SOFTWARE);
	SDL_ShowCursor(SDL_DISABLE);
	TTF_Init();
	fonts();
	for (int i = 0; i < SDL_NumJoysticks(); i++)
		SDL_JoystickOpen(i);

	/* ignore input for a moment so the press that opened us does not close us */
	Uint32 start = SDL_GetTicks(), last = 0;
	for (;;) {
		SDL_Event e;
		while (SDL_PollEvent(&e)) {
			int press = e.type == SDL_JOYBUTTONDOWN || e.type == SDL_KEYDOWN ||
				    e.type == SDL_CONTROLLERBUTTONDOWN;
			if (e.type == SDL_QUIT || (press && SDL_GetTicks() - start > 500))
				goto out;
		}
		if (!last || SDL_GetTicks() - last >= 1000) {
			last = SDL_GetTicks();
			draw();
			SDL_RenderPresent(R);
		}
		SDL_Delay(30);
	}
out:
	SDL_Quit();
	return 0;
}
