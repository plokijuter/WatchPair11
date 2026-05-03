#import "ViewController.h"
#import "Installer.h"

@interface ViewController ()
@property (nonatomic, strong) UILabel *statusTweakLabel;
@property (nonatomic, strong) UILabel *statusPayLabel;
@property (nonatomic, strong) UILabel *statusBuildLabel;
@property (nonatomic, strong) UIButton *btnPay;
@property (nonatomic, strong) UIButton *btnRollback;
@property (nonatomic, strong) UIButton *btnRespring;
@property (nonatomic, strong) UIButton *btnReboot;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) Installer *installer;
@property (nonatomic, assign) BOOL busy;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"WatchPair11";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.installer = [[Installer alloc] init];
    [self buildUI];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self refreshStatus];
}

#pragma mark - UI

- (UIButton *)makeButton:(NSString *)title color:(UIColor *)color action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.backgroundColor = color;
    b.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    b.layer.cornerRadius = 10;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [b.heightAnchor constraintEqualToConstant:50].active = YES;
    return b;
}

- (UILabel *)makeStatusLabel {
    UILabel *l = [[UILabel alloc] init];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.font = [UIFont systemFontOfSize:14];
    l.textColor = [UIColor labelColor];
    return l;
}

- (void)buildUI {
    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    stack.alignment = UIStackViewAlignmentFill;
    [self.view addSubview:stack];

    NSString *bundleVer = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?";
    UILabel *header = [[UILabel alloc] init];
    header.text = [NSString stringWithFormat:@"WatchPair11 v%@", bundleVer];
    header.font = [UIFont boldSystemFontOfSize:22];
    header.numberOfLines = 0;
    [stack addArrangedSubview:header];

    UILabel *sub = [[UILabel alloc] init];
    sub.text = @"watchOS 11.5 ↔ iOS 16\nPairing + notifs : auto-installed by the package.\nApple Pay : optional, tap below.";
    sub.font = [UIFont systemFontOfSize:13];
    sub.textColor = [UIColor secondaryLabelColor];
    sub.numberOfLines = 0;
    [stack addArrangedSubview:sub];

    self.statusTweakLabel = [self makeStatusLabel];
    self.statusPayLabel = [self makeStatusLabel];
    self.statusBuildLabel = [self makeStatusLabel];
    [stack addArrangedSubview:self.statusTweakLabel];
    [stack addArrangedSubview:self.statusPayLabel];
    [stack addArrangedSubview:self.statusBuildLabel];

    UIView *spacer = [[UIView alloc] init];
    [spacer.heightAnchor constraintEqualToConstant:8].active = YES;
    [stack addArrangedSubview:spacer];

    self.btnPay = [self makeButton:@"Setup Apple Pay"
                             color:[UIColor systemGreenColor]
                            action:@selector(onInstallPay)];
    self.btnRollback = [self makeButton:@"Rollback Apple Pay"
                                  color:[UIColor systemRedColor]
                                 action:@selector(onRollback)];
    [stack addArrangedSubview:self.btnPay];
    [stack addArrangedSubview:self.btnRollback];

    UIView *spacer2 = [[UIView alloc] init];
    [spacer2.heightAnchor constraintEqualToConstant:6].active = YES;
    [stack addArrangedSubview:spacer2];

    self.btnRespring = [self makeButton:@"Respring"
                                  color:[UIColor systemGrayColor]
                                 action:@selector(onRespring)];
    self.btnReboot = [self makeButton:@"Userspace Reboot (re-JB)"
                                color:[UIColor systemOrangeColor]
                               action:@selector(onUserspaceReboot)];
    [stack addArrangedSubview:self.btnRespring];
    [stack addArrangedSubview:self.btnReboot];

    self.logView = [[UITextView alloc] init];
    self.logView.translatesAutoresizingMaskIntoConstraints = NO;
    self.logView.editable = NO;
    self.logView.font = [UIFont fontWithName:@"Menlo" size:11];
    self.logView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.logView.textColor = [UIColor labelColor];
    self.logView.layer.cornerRadius = 8;
    [stack addArrangedSubview:self.logView];

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:g.topAnchor constant:16],
        [stack.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-16],
        [stack.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-16],
    ]];
}

#pragma mark - Status

- (void)refreshStatus {
    BOOL tweak = [Installer isTweakInstalled];
    BOOL pay = [Installer isApplePayInstalled];
    BOOL nathan = [Installer isNathanlrAvailable];
    NSString *build = [Installer detectedIOSBuild];

    self.statusTweakLabel.text = [NSString stringWithFormat:@"Tweak : %@", tweak ? @"✅ active" : @"❌ missing — reinstall the .deb"];
    self.statusPayLabel.text = [NSString stringWithFormat:@"Apple Pay : %@", pay ? @"✅ installed" : @"⚪ not yet"];
    self.statusBuildLabel.text = [NSString stringWithFormat:@"iOS %@ · JB : %@", build, nathan ? @"nathanlr ok" : @"⚠️ not detected"];
}

#pragma mark - Logging

- (void)appendLog:(NSString *)line {
    NSString *cur = self.logView.text ?: @"";
    self.logView.text = [cur stringByAppendingFormat:@"%@\n", line];
    NSRange r = NSMakeRange(self.logView.text.length, 0);
    [self.logView scrollRangeToVisible:r];
}

- (void)clearLog { self.logView.text = @""; }

- (void)setBusy:(BOOL)busy {
    _busy = busy;
    for (UIButton *b in @[self.btnPay, self.btnRollback, self.btnRespring, self.btnReboot]) {
        b.enabled = !busy;
        b.alpha = busy ? 0.5 : 1.0;
    }
}

#pragma mark - Actions

- (void)onInstallPay {
    if (self.busy) return;
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"Setup Apple Pay?"
                         message:@"This deploys passd hooks + PassKit prefs. You must reboot + re-JB after. Continue?"
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Install" style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction *x) { [self doInstallPay]; }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)doInstallPay {
    [self clearLog];
    [self setBusy:YES];
    __weak typeof(self) ws = self;
    [self.installer installApplePayWithLog:^(NSString *line) {
        [ws appendLog:line];
    } done:^(BOOL success, NSString *error) {
        [ws setBusy:NO];
        [ws refreshStatus];
        if (!success) [ws showAlert:@"Install failed" msg:error];
    }];
}

- (void)onRollback {
    if (self.busy) return;
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"Rollback Apple Pay?"
                         message:@"Removes Apple Pay setup. The pairing tweak stays active. Continue?"
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Rollback" style:UIAlertActionStyleDestructive
                                       handler:^(UIAlertAction *x) { [self doRollback]; }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)doRollback {
    [self clearLog];
    [self setBusy:YES];
    __weak typeof(self) ws = self;
    [self.installer rollbackApplePayWithLog:^(NSString *line) {
        [ws appendLog:line];
    } done:^(BOOL success, NSString *error) {
        [ws setBusy:NO];
        [ws refreshStatus];
        if (!success) [ws showAlert:@"Rollback failed" msg:error];
    }];
}

- (void)onRespring {
    if (self.busy) return;
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"Respring?"
                         message:@"Restart SpringBoard. The home screen will refresh in ~2s. This app will close."
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Respring" style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction *x) {
        [self clearLog];
        [self setBusy:YES];
        [self.installer respringWithLog:^(NSString *line) { [self appendLog:line]; }
                                  done:^(BOOL ok, NSString *err) { /* app dies */ }];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)onUserspaceReboot {
    if (self.busy) return;
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"Userspace Reboot?"
                         message:@"Restart all userspace processes. Faster than full reboot. JB stays active if your loader auto-runs; otherwise re-launch nathanlr after."
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Reboot Userspace" style:UIAlertActionStyleDestructive
                                       handler:^(UIAlertAction *x) {
        [self clearLog];
        [self setBusy:YES];
        [self.installer userspaceRebootWithLog:^(NSString *line) { [self appendLog:line]; }
                                         done:^(BOOL ok, NSString *err) { /* device reboots */ }];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)showAlert:(NSString *)title msg:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
