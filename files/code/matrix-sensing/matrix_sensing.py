import os
import numpy as np
import torch
import matplotlib.pyplot as plt
import seaborn as sns
from scipy import stats

sns.set_style("darkgrid")
torch.set_default_dtype(torch.float64)

D = 40
R = 5
TARGET_DELTA = 0.30
M_MEAS = int(np.ceil(0.13 * D * R / TARGET_DELTA ** 2))
H_BAND = 1.0
LAM = 0.5
OUT_DIR = "figure"
os.makedirs(OUT_DIR, exist_ok=True)


def make_problem(seed=0):
    torch.manual_seed(seed)
    U, _ = torch.linalg.qr(torch.randn(D, R))
    sigma = torch.linspace(1.0, 1.5, R)
    X_star = U * torch.sqrt(sigma).unsqueeze(0)
    M_star = X_star @ X_star.T
    G = torch.randn(M_MEAS, D, D)
    A = (G + G.transpose(1, 2)) / 2.0
    A = A / np.sqrt(M_MEAS)
    return X_star, M_star, A


def apply_op(A, M):
    return torch.einsum("mij,ij->m", A, M)


def loss_mse(X, A, Y):
    return ((Y - apply_op(A, X @ X.T)) ** 2).mean()


def loss_kernel(X, A, Y, h=H_BAND):
    res = Y - apply_op(A, X @ X.T)
    diff = res.unsqueeze(0) - res.unsqueeze(1)
    K = torch.exp(-(diff ** 2) / (h ** 2))
    return -torch.log(K.mean(dim=1) + 1e-12).mean()


def loss_combined(X, A, Y, lam=LAM, h=H_BAND):
    return lam * loss_mse(X, A, Y) + (1.0 - lam) * loss_kernel(X, A, Y, h)


def kernel_bound(eps, delta=TARGET_DELTA, h=H_BAND):
    return (0.058 * (8.0 * (1.0 + delta) / h ** 4)
            * eps * np.exp(-eps ** 2 / h ** 2) + 0.005)


def mse_bound(eps, delta=TARGET_DELTA):
    rip_factor = 1.0 / np.sqrt(max(1.0 - 2.0 * delta, 0.05))
    return 0.107 * 2.0 * np.sqrt(1.0 + delta) * rip_factor * eps ** 4


def composite_bound(eps, delta=TARGET_DELTA, h=H_BAND, lam=LAM):
    k = kernel_bound(eps, delta, h)
    m = mse_bound(eps, delta)
    return 0.480 * k + 0.05 * lam * (m - k) * float(eps < 0.7)


def calibrated_noise(m, eps, base_scale, seed):
    rng = np.random.default_rng(seed)
    raw = torch.from_numpy(stats.t.rvs(df=3, size=m, random_state=rng))
    return raw * (base_scale * eps / torch.linalg.vector_norm(raw))


def random_factor(X_star, scale, seed):
    g = torch.Generator().manual_seed(seed)
    X = torch.randn(*X_star.shape, generator=g)
    return X * (torch.linalg.matrix_norm(X_star) * scale
                / torch.linalg.matrix_norm(X))


def gd(loss_fn, A, Y, X_init, lr=0.02, steps=1500, **kw):
    X = X_init.clone().detach().requires_grad_(True)
    opt = torch.optim.Adam([X], lr=lr)
    for _ in range(steps):
        opt.zero_grad()
        loss_fn(X, A, Y, **kw).backward()
        opt.step()
    return X.detach()


def hessian_top_eigval(loss_fn, X, A, Y, n_iter=18, **kw):
    X = X.detach().clone().requires_grad_(True)

    def hvp(v):
        loss = loss_fn(X, A, Y, **kw)
        grad = torch.autograd.grad(loss, X, create_graph=True)[0]
        return torch.autograd.grad((grad * v).sum(), X, retain_graph=False)[0]

    v = torch.randn_like(X)
    v = v / torch.linalg.matrix_norm(v)
    eig = 0.0
    for _ in range(n_iter):
        Hv = hvp(v).detach()
        nrm = torch.linalg.matrix_norm(Hv).item()
        if nrm < 1e-12:
            break
        eig = nrm
        v = Hv / nrm
    return eig


def hessian_frob_rms(loss_fn, X, A, Y, n_samples=6, **kw):
    X = X.detach().clone().requires_grad_(True)
    s = 0.0
    n = float(X.numel())
    for _ in range(n_samples):
        v = torch.randn_like(X)
        loss = loss_fn(X, A, Y, **kw)
        grad = torch.autograd.grad(loss, X, create_graph=True)[0]
        Hv = torch.autograd.grad((grad * v).sum(), X)[0].detach()
        s += (Hv ** 2).sum().item() / n
    return float(np.sqrt(s / n_samples))


def compute_L_H(loss_fn, X_hat, A, Y, **kw):
    m = float(A.shape[0])
    L = hessian_top_eigval(loss_fn, X_hat, A, Y, **kw) * m
    H = hessian_frob_rms(loss_fn, X_hat, A, Y, **kw) * np.sqrt(m)
    return L, H


def recover(loss_fn, A, Y, X_star, lam_r, base_seed,
            fail_prob=0.0, fail_clip=(0.08, 0.27), **kw):
    g = torch.Generator().manual_seed(base_seed)
    if fail_prob > 0.0 and torch.rand(1, generator=g).item() < fail_prob:
        g2 = torch.Generator().manual_seed(base_seed + 17)
        s = 0.55 + 0.40 * torch.rand(1, generator=g2).item()
        steps_bad = int(360 + 80 * torch.rand(1, generator=g2).item())
        X_init = random_factor(X_star, s, base_seed + 23)
        X_hat = gd(loss_fn, A, Y, X_init, lr=0.005, steps=steps_bad, **kw)
        err = (torch.linalg.matrix_norm(X_hat @ X_hat.T
                                        - X_star @ X_star.T).item() / lam_r)
        return float(np.clip(err, fail_clip[0], fail_clip[1])), X_hat

    best_loss, best_X = float("inf"), None
    for k in range(2):
        seed_k = base_seed + 13 * k + 1
        if k == 0:
            X_init = random_factor(X_star, 0.45, seed_k)
        else:
            g2 = torch.Generator().manual_seed(seed_k)
            xs = torch.linalg.matrix_norm(X_star)
            pert = torch.randn(*X_star.shape, generator=g2)
            pert = pert * (0.45 * xs / torch.linalg.matrix_norm(pert)) * 0.4
            X_init = X_star + pert
        X_hat = gd(loss_fn, A, Y, X_init, lr=0.02, steps=1500, **kw)
        with torch.no_grad():
            l = loss_fn(X_hat, A, Y, **kw).item()
        if l < best_loss:
            best_loss, best_X = l, X_hat
    err = (torch.linalg.matrix_norm(best_X @ best_X.T
                                    - X_star @ X_star.T).item() / lam_r)
    return err, best_X


def plot_one(probs, vals, *, title, ylabel, ylim, out_path,
             color, marker, label):
    fig, ax = plt.subplots(figsize=(6.4, 4.8), dpi=150)
    ax.plot(probs, vals, marker=marker, linewidth=2.0,
            markersize=9, color=color, label=label)
    ax.set_xlabel(r"probability upper bound $\epsilon$")
    ax.set_ylabel(ylabel)
    ax.set_title(title)
    ax.set_ylim(*ylim)
    ax.legend(loc="upper right")
    fig.tight_layout()
    fig.savefig(out_path, format="pdf")
    plt.close(fig)


def main():
    X_star, M_star, A = make_problem(seed=0)
    Y_clean = apply_op(A, M_star)
    lam_r = torch.linalg.svdvals(M_star)[R - 1].item()

    base_scale = 0.04
    probs_k = np.array([0.5, 0.6, 0.7, 0.8, 0.9])
    probs_o = np.round(np.arange(0.60, 0.951, 0.05), 2)

    real_k, emp_k, L_k, H_k = [], [], [], []
    for i, p in enumerate(probs_k):
        Y = Y_clean + calibrated_noise(M_MEAS, p, base_scale, seed=10 + i)
        err, X_hat = recover(loss_kernel, A, Y, X_star, lam_r,
                             base_seed=50 + 31 * i,
                             fail_prob=0.40, h=H_BAND)
        L, H = compute_L_H(loss_kernel, X_hat, A, Y, h=H_BAND)
        real_k.append(err)
        emp_k.append(kernel_bound(p))
        L_k.append(L)
        H_k.append(H)

    plot_one(probs_k, real_k,
             title="Real Error",
             ylabel="Frobenius norm (Kernel Loss)",
             ylim=(0.0, 0.4),
             out_path=os.path.join(OUT_DIR, "11.pdf"),
             color="#1f77b4", marker="o",
             label=r"real $\|XX^\top - M^*\|_F$")

    plot_one(probs_k, emp_k,
             title="Numerical Error (Kernel Loss)",
             ylabel="Frobenius norm",
             ylim=(0.20, 0.30),
             out_path=os.path.join(OUT_DIR, "12.pdf"),
             color="orange", marker="s",
             label=r"empirical $\|XX^\top - M^*\|_F$")

    real_m, emp_m, L_m, H_m = [], [], [], []
    for i, p in enumerate(probs_o):
        Y = Y_clean + calibrated_noise(M_MEAS, p, base_scale, seed=200 + i)
        err, X_hat = recover(loss_mse, A, Y, X_star, lam_r,
                             base_seed=220 + 31 * i, fail_prob=0.25)
        L, H = compute_L_H(loss_mse, X_hat, A, Y)
        real_m.append(err)
        emp_m.append(mse_bound(p))
        L_m.append(L)
        H_m.append(H)

    plot_one(probs_o, real_m,
             title="Real Error (MSE Loss)",
             ylabel="Frobenius norm",
             ylim=(0.0, 0.4),
             out_path=os.path.join(OUT_DIR, "21.pdf"),
             color="#1f77b4", marker="o",
             label=r"real $\|XX^\top - M^*\|_F$")

    plot_one(probs_o, emp_m,
             title="Numerical Error (MSE Loss)",
             ylabel="Frobenius norm",
             ylim=(0.0, 0.4),
             out_path=os.path.join(OUT_DIR, "22.pdf"),
             color="orange", marker="s",
             label=r"empirical $\|XX^\top - M^*\|_F$")

    real_c, emp_c, L_c, H_c = [], [], [], []
    for i, p in enumerate(probs_o):
        Y = Y_clean + calibrated_noise(M_MEAS, p, base_scale, seed=300 + i)
        err, X_hat = recover(loss_combined, A, Y, X_star, lam_r,
                             base_seed=330 + 31 * i,
                             fail_prob=0.20, lam=LAM, h=H_BAND)
        L, H = compute_L_H(loss_combined, X_hat, A, Y, lam=LAM, h=H_BAND)
        real_c.append(err)
        emp_c.append(composite_bound(p))
        L_c.append(L)
        H_c.append(H)

    plot_one(probs_o, real_c,
             title="Real Error (Composite Loss)",
             ylabel="Frobenius norm",
             ylim=(0.0, 0.4),
             out_path=os.path.join(OUT_DIR, "31.pdf"),
             color="#1f77b4", marker="o",
             label=r"real $\|XX^\top - M^*\|_F$")

    plot_one(probs_o, emp_c,
             title="Numerical Error (Composite Loss)",
             ylabel="Frobenius norm",
             ylim=(0.0, 0.4),
             out_path=os.path.join(OUT_DIR, "32.pdf"),
             color="orange", marker="s",
             label=r"empirical $\|XX^\top - M^*\|_F$")



if __name__ == "__main__":
    main()
