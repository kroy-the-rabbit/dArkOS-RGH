/*
 * AXP717 power key: enable long-press power-off and the 16 s PMIC reset.
 * The board ships with both disabled. The bits are POR-reset, so they
 * survive later hangs and power-offs until the battery is disconnected.
 *
 *   REG22 bit1  PWRON > OFFLEVEL as power-off source
 *   REG26 [3:2] OFFLEVEL: 00 4s, 01 6s, 10 8s, 11 10s
 *   REG27 bit2  PWRON 16s shuts down the PMIC
 */
#include <fcntl.h>
#include <linux/i2c.h>
#include <linux/i2c-dev.h>
#include <stdio.h>
#include <sys/ioctl.h>
#include <unistd.h>

static int fd;

static int rd(unsigned char reg)
{
	union i2c_smbus_data d;
	struct i2c_smbus_ioctl_data a = { I2C_SMBUS_READ, reg, I2C_SMBUS_BYTE_DATA, &d };
	return ioctl(fd, I2C_SMBUS, &a) < 0 ? -1 : d.byte;
}

static int wr(unsigned char reg, unsigned char v)
{
	union i2c_smbus_data d = { .byte = v };
	struct i2c_smbus_ioctl_data a = { I2C_SMBUS_WRITE, reg, I2C_SMBUS_BYTE_DATA, &d };
	return ioctl(fd, I2C_SMBUS, &a);
}

static int set(unsigned char reg, unsigned char mask, unsigned char val)
{
	int o = rd(reg);
	if (o < 0)
		return -1;
	int n = (o & ~mask) | val;
	if (n != o && wr(reg, n) < 0)
		return -1;
	printf("reg %02x: %02x -> %02x\n", reg, o, rd(reg));
	return 0;
}

int main(void)
{
	fd = open("/dev/i2c-0", O_RDWR);
	/* the axp20x driver owns 0x34; these registers are not touched by it */
	if (fd < 0 || ioctl(fd, I2C_SLAVE_FORCE, 0x34) < 0) {
		perror("axp717");
		return 1;
	}
	if (set(0x22, 0x02, 0x02) || set(0x26, 0x0c, 0x04) || set(0x27, 0x04, 0x04)) {
		perror("axp717");
		return 1;
	}
	return 0;
}
