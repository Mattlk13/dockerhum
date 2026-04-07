<?php

/**
 * @link https://www.humhub.org/
 * @copyright Copyright (c) 2025 HumHub GmbH & Co. KG
 * @license https://www.humhub.com/licences
 */

use humhub\services\BootstrapService;

/**
 * @var $loader \Composer\Autoload\ClassLoader
 */
$loader = require('/opt/humhub/protected/vendor/autoload.php');

// Load Environment
$dotenv = Dotenv\Dotenv::createImmutable(__DIR__, '.env');
$dotenv->safeLoad();

$humhubSrcPath = '/opt/humhub/protected/humhub';

// Load Bootstrap Helper
$loader->addClassMap(['humhub\\services\\BootstrapService' => $humhubSrcPath . '/services/BootstrapService.php']);

$bootstrap = new BootstrapService();
$bootstrap->setPaths(config: '/data/config');
$bootstrap->runWeb();