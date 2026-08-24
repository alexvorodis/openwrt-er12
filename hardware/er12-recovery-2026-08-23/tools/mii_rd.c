/* mii_rd.c — read MDIO registers of any PHY addr reachable from a netdev's phydev
 * Usage: mii_rd <ifname> <phy_addr> [reg]   (default reg=1, BMSR)
 * Prints hex value. Uses SIOCGMIIREG (phylib generic ioctl).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <net/if.h>
#include <linux/sockios.h>
#include <linux/mii.h>

int main(int argc, char **argv)
{
	if (argc < 3) { fprintf(stderr, "usage: %s <ifname> <phy> [reg]\n", argv[0]); return 2; }
	const char *ifn = argv[1];
	int phy = (int)strtol(argv[2], NULL, 0);
	int reg = argc > 3 ? (int)strtol(argv[3], NULL, 0) : 1;

	int fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd < 0) { perror("socket"); return 1; }
	struct ifreq ir;
	memset(&ir, 0, sizeof(ir));
	strncpy(ir.ifr_name, ifn, IFNAMSIZ - 1);

	struct mii_ioctl_data *mii = (struct mii_ioctl_data *)&ir.ifr_data;
	mii->phy_id  = (unsigned short)phy;
	mii->reg_num = (unsigned short)reg;
	mii->val_out = 0;

	if (ioctl(fd, SIOCGMIIREG, &ir) < 0) { perror("SIOCGMIIREG"); close(fd); return 1; }
	printf("0x%04x\n", mii->val_out);
	close(fd);
	return 0;
}
