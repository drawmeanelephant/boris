// Static benchmark asset. The migration lab inventories it but never executes it.
document.querySelectorAll('.menu-toggle').forEach(function (button) {
  button.addEventListener('click', function () { document.body.classList.toggle('menu-open'); });
});
